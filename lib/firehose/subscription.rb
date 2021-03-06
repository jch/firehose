module Firehose
  class Subscription
    TTL = 15000

    # Time to live for the queue on the server after the subscription is canceled. This
    # is mostly for flakey connections where the client may reconnect after *ttl* and continue
    # receiving messages.
    attr_accessor :ttl

    # Globally unique subscription id
    attr_reader :subscriber_id

    def initialize(subscriber_id=nil)
      @subscriber_id = subscriber_id || self.class.subscriber_id
    end

    # TODO - Move the path to an initializer so that we can force on AMQP subscription per one
    # Firehose subscription. As it stands now, you could fire off multple subscriptions to diff channels
    def subscribe(path, &block)
      queue_name  = "#{subscriber_id}@#{path}"
      channel     = AMQP::Channel.new(Firehose.amqp.connection).prefetch(1)
      exchange    = AMQP::Exchange.new(channel, :fanout, path, :auto_delete => true)
      queue       = AMQP::Queue.new(channel, queue_name, :arguments => {'x-expires' => ttl})
      queue.bind(exchange)

      # When we get a message, we want to remove the consumer from the queue so that the x-expires
      # ttl starts ticking down. On the reconnect, the consumer connects to the queue and resets the
      # timer on x-expires... in theory at least.
      @consumer = AMQP::Consumer.new(channel, queue, subscriber_id)
      @consumer.on_delivery do |metadata, message|
        Firehose.logger.debug "AMQP delivering `#{message}` to `#{subscriber_id}@#{path}`"
        block.call(message)
        # The ack needs to go after the block is called. This makes sure that all processing
        # happens downstream before we remove it from the queue entirely.
        metadata.ack
      end.consume
      Firehose.logger.debug "AMQP subscribed to `#{subscriber_id}@#{path}`"
    end

    def unsubscribe
      Firehose.logger.debug "AMQP unsubscribed"
      @consumer.cancel if @consumer
    end

    # The time that a queue should live *after* the client unsubscribes. This is useful for
    # flakey network connections, like HTTP Long Polling or even broken web sockets.
    def ttl
      @ttl ||= TTL
    end

  protected
    def self.subscriber_id
      rand(999_999_999_999).to_s
    end
  end
end