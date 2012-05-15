=begin
    Copyright 2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'arachni/rpc/em'

#
# Exports the API of a {Crawler} instance over an RPC protocol (in this case, Arachni-RPC).
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Roundabout::RPC::Server
    def initialize( opts )
        server = ::Arachni::RPC::EM::Server.new( opts )
        server.logger.level = Logger::FATAL

        #
        # Methods that expect a block are async
        #
        # I.e. they pass their result to their given block and don't return it
        #
        server.add_async_check do |method|
            method.parameters.flatten.include?( :block )
        end

        @crawler = Roundabout::Crawler.new( opts )
        @distributor = @crawler.distributor

        server.add_handler( 'crawler', @crawler )
        server.add_handler( 'node', self )
        server.run

        opts[:peers].each { |p| add_peer( p ) }

        puts
        puts 'Wait for more peers to join or hit "enter" to start the crawl.'

        ::EM.defer {
            gets
            set_on_complete_handler
            @crawler.run
        }
    end

    def shutdown
        ::EM.stop
    end

    def add_peer( url )
        peer_urls = @distributor.peer_urls
        return false if peer_urls.include?( url )

        puts "--- [JOIN] #{url}"

        crawler = connect( url )
        peer = connect_to_node( url )
        @distributor.add_peers( crawler )
        peer_urls.each { |p| peer.add_peer( p ){} }
        true
    end

    private
    def set_on_complete_handler
        @crawler.on_complete {
            puts 'DONE!'
            ::EM.add_periodic_timer( 1 ) {
                puts 'Checking peer statuses.'

                all_done? do |res|
                    if res
                        puts 'All done, collecting sitemaps...'
                        collect_sitemaps do |sitemap|
                            ap sitemap
                            kill_all { ::EM.stop }
                        end
                    else
                        puts 'Still working...'
                    end
                end
            }
        }
    end

    def all_done?( &block )
        raise 'Required block missing!' if !block_given?
        statuses = [ @crawler.done? ]

        foreach = proc { |peer, iter| connect( peer ).done? { |s| iter.return( s ) } }
        after = proc { |s| block.call( !(statuses | s).flatten.include?( false ) ) }
        map_peers( foreach, after )
    end

    def collect_sitemaps( &block )
        raise 'Required block missing!' if !block_given?

        foreach = proc { |peer, iter| connect( peer ).sitemap_as_array { |s| iter.return( s ) } }
        after = proc { |sitemap| block.call( (sitemap | @crawler.sitemap_as_array).flatten.uniq ) }
        map_peers( foreach, after )
    end

    def kill_all( &block )
        foreach = proc { |url, iter| connect_to_node( url ).shutdown{ iter.return } }
        after = proc { block.call if block_given? }
        map_peers( foreach, after )
    end

    def map_peers( foreach, after )
        peer_iter.map( foreach, after )
    end

    def each_peer( foreach )
        peer_iter.each( foreach )
    end

    def peer_iter
        peer_urls = @distributor.peer_urls.reject { |url| url == @crawler.peer_url }
        ::EM::Iterator.new( peer_urls, peer_urls.size )
    end

    def connect( url )
        Roundabout::RPC::Client.connect( url )
    end

    def connect_to_node( url )
        Roundabout::RPC::Client.connect_to_node( url )
    end
end
