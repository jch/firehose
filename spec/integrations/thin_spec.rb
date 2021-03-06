require 'spec_helper'
require 'thin'
require 'em-http'

describe Firehose::Rack do
  let(:app)       { Firehose::Rack::App.new }
  let(:messages)  { (1..1000).map(&:to_s) }
  let(:channel)   { "/firehose/integration/#{Time.now.to_i}" }
  let(:uri)       { URI.parse('http://127.0.0.1:9876') }
  let(:url)       { "#{uri}#{channel}" }
  let(:ws_url)    { "ws://#{uri.host}:#{uri.port}#{channel}" }
  let(:cid)       { "client-#{Time.now.to_i}" }

  it "should pub-sub http and websockets" do
    # Setup variables that we'll use after we turn off EM to validate our
    # test assertions.
    outgoing, received_http, received_ws = messages.dup, [], []

    # Our WS and Http clients call this when they have received their messages to determine
    # when to turn off EM and make the test assertion at the very bottom.
    succeed = Proc.new do
      EM.stop if received_http.size == messages.size and received_ws.size == messages.size
    end

    # Setup a publisher
    publish = Proc.new do
      http = EM::HttpRequest.new(url).put(:body => outgoing.pop)
      http.errback  { EM.stop }
      http.callback { publish.call unless outgoing.empty? }
    end

    # Lets have an HTTP Long poll client
    http_long_poll = Proc.new do
      http = EM::HttpRequest.new(url).get(:query => {'cid' => cid})
      http.errback { EM.stop }
      http.callback do
        received_http << http.response
        if received_http.size < messages.size
          http_long_poll.call
        else
          succeed.call
        end
      end
    end

    # And test a web socket client too, at the same time.
    websocket = Proc.new do
      http = EventMachine::HttpRequest.new(ws_url).get
      http.errback  { EM.stop }
      http.stream do |msg|
        received_ws << msg
        succeed.call unless received_ws.size < messages.size
      end
    end

    # Great, we have all the pieces in order, lets run this thing in the reactor.
    EM.run do
      # Stop the server no matter what happens.
      EM.add_timer(30) { EM.stop }

      # Start the server
      ::Thin::Server.new(uri.host, uri.port, app).start

      # Start the http_long_pollr.
      http_long_poll.call
      websocket.call

      # Wait a sec to let our http_long_poll setup.
      EM.add_timer(1){ publish.call }
    end

    # When EM stops, these assertions will be made.
    received_http.should  =~ messages
    received_ws.should    =~ messages
  end
end