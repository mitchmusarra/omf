
require 'rubygems'
require 'xmpp4r'
require 'omf-common/omfXMPPServices'

#Jabber::debug = true
module OMF
  module XMPP
    CONNECTION_TIMEOUT = 10
    READ_TIMEOUT = 5

    module PubSub
    end

    class XmppError < Exception; end
    class ConnectionTimeout < XmppError; end
    class ReadTimeout < XmppError; end
    class NoService < XmppError; end
    class ServerError < XmppError; end
    class Misconfigured < XmppError; end

    module Safely
      def with_timeout(timeout, exception, &block)
        Timeout::timeout(timeout, exception, &block)
      end

      def with_connect_timeout(&block)
        with_timeout(CONNECTION_TIMEOUT, ConnectionTimeout, &block)
      end

      def with_read_timeout(&block)
        with_timeout(READ_TIMEOUT, ReadTimeout, &block)
      end

      def nonblocking(type=:read, &block)
        case type
        when :read then with_read_timeout(&block)
        when :connect then with_connect_timeout(&block)
        else
          raise XmppError, "Unknown nonblocking type '#{type}'"
        end
      end

      #
      # Execute a block, catch its exceptions, and map them to
      # well-defined exceptions for this module, derived from
      # XmppException, then re-throw them.
      #
      def clean_exceptions(&block)
        begin
          block.call
        rescue Jabber::ServerError => e
          raise ServerError, e.message
        rescue ConnectionTimeout, Errno::ETIMEDOUT => e
          raise ConnectionTimeout, e.message
        rescue SystemCallError => e
          raise NoService, e.message
        rescue ReadTimeout => e
          raise e
        rescue Exception => e
          raise XmppError, e.message
        end
      end

      def handle(errors, &block)
        begin
          block.call
        rescue Jabber::ServerError => e
          errors.each_pair do |err, block|
            if e.error.type == :cancel and e.error.error == err
              return block.call
            end
          end
          raise e
        end
      end

      def ignore(errors, &block)
        begin
          block.call
        rescue Jabber::ServerError => e
          errors.each do |err|
            if e.error.type == :cancel and e.error.error == err
              return
            end
          end
          raise e
        end
      end
    end # module Safely

    class Connection < MObject
      include OMF::XMPP::Safely
      @connected = false
      @client = nil
      @password = nil
      @mutex = nil

      attr_reader :client

      def initialize(gateway, user, password)
        raise Misconfigured, "Must specify XMPP gateway" if gateway.nil?
        raise Misconfigured, "Must specify XMPP user name" if user.nil?
        raise Misconfigured, "Must specify XMPP user password" if password.nil?

        jid = "#{user}@#{gateway}"
        @gateway = gateway
        @password = password
        @mutex = Mutex.new
        @connected = false
        @client = Jabber::Client.new(jid)
      end

      def connected?
        @connected
      end

      #
      # Connect to the XMPP server.  OMF requires a slightly more
      # managed connection than that offered by XMPP4r's
      # Jabber::Client class, so we take care of:
      #
      #  1. connecting to the pubsub gateway
      #  2. registering the user (if not already existing)
      #  3. authenticating the user (if already existing)
      #  4. sending the presence notification
      #
      def connect
        @mutex.synchronize {
          return if @connected

          begin
            clean_exceptions {
              nonblocking(:connect) {
                @client.connect(@gateway)
              }

              # Register, but if the user is already registered, authenticate instead
              nonblocking {
                handle("conflict" => lambda { @client.auth(@password) }) {
                  @client.register(@password)
                }
              }

              nonblocking { @client.send(Jabber::Presence.new) }
              @connected = true
            }
          rescue Exception => e
            @client.close
            @connected = false
            raise e
          end
        }
      end

      def close
        @mutex.synchronize {
          clean_exceptions { nonblocking { @client.close } }
          @connected  = false
        }
      end

      #
      # Send a ping to the PubSub server
      # implemented according to
      # http://xmpp.org/extensions/xep-0199.html#c2s
      #
      def ping
        iq = Jabber::Iq.new(:get, @client.jid.domain)
        iq.from = @client.jid
        ping = iq.add(REXML::Element.new('ping'))
        ping.add_namespace 'urn:xmpp:ping'
        @client.send_with_id(iq) do |reply|
          ret = reply.kind_of?(Jabber::Iq) and reply.type == :result
        end
      end
    end # class Connection

    module PubSub
      class ServiceHelper < OmfServiceHelper
        def unsubscribe_from(node, subid=nil)
          unsubscribe_from_fixed(node, subid)
        end
      end # class ServiceHelper

      class Listener
        @node = nil
        @subscription
        @queue = nil

        attr_reader :node, :subscription, :queue

        # node:: [String]
        # subscription:: [Jabber::PubSub::Subscription]
        # queue:: [Queue]
        def initialize(node, subscription, queue = nil)
          @node = node
          @subscription = subscription
          @queue = queue || Queue.new
        end
      end # class Listener

      class Domain
        include OMF::XMPP::Safely
        @name = nil
        @service_helper = nil
        @subscriptions = nil
        @listeners = nil
        @mutex = nil
        @event_count = 0

        def initialize(connection, domain)
          @event_count = 0
          @name = domain
          @subscriptions = Hash.new
          @listeners = Hash.new
          @mutex = Mutex.new
          clean_exceptions {
            @service_helper = PubSub::ServiceHelper.new(connection.client, "pubsub.#{domain}")
            @service_helper.add_event_callback { |event| process_event(event) }
          }
        end

        def event_node(event)
          items = event.first_element("items")
          return nil if items.nil?
          return items.attributes['node']
        end

        def event_payload(event)
          items = event.first_element("items")
          return nil if items.nil?
          item = items.first_element("item")
          return nil if item.nil?

          payload = item.elements[1]
          return payload
        end

        def process_event(event)
          c = @event_count
          puts "event: #{c}"
          @event_count += 1
          listeners = nil
          node = event_node(event)
          payload = event_payload(event)
          @mutex.synchronize {
            if @listeners.has_key? node
              listeners = @listeners[node].clone
            end
          }
          listeners.each { |s| s.queue << payload } if not listeners.nil? and not payload.nil?
        end

        def create_node(node, opts=nil)
          opts = opts || {
            "pubsub#title" => "#{name}",
            "pubsub#node_type" => "leaf",
            "pubsub#persist_items" => "1",
            "pubsub#max_items" => "1",
            "pubsub#notify_retract" => "0",
            "pubsub#publish_model" => "open"
          }

          config = config || Jabber::PubSub::NodeConfig.new(nil, opts)
          clean_exceptions { nonblocking { @service_helper.create_node(node, config) } }
        end

        def publish_to_node(node, item)
          clean_exceptions { nonblocking { @service_helper.publish_item_to(node,item) } }
        end

        def listen_to_node(node, queue = nil)
          listener = nil
          sub = nil
          @mutex.synchronize {
            sub = @subscriptions[node]
          }
          if sub.nil?
            resp = clean_exceptions { nonblocking { @service_helper.subscribe_to(node) } }
          end
          @mutex.synchronize {
            @subscriptions[node] = resp
            listener = Listener.new(node, @subscriptions[node], queue)
            listeners = @listeners[node] || []
            listeners << listener
            @listeners[node] = listeners
          }
          listener
        end

        def unlisten(listener)
          node = listener.node
          subid = listener.subscription.subid
          empty = false
          @mutex.synchronize {
            listeners = @listeners[node]
            listeners.delete(listener)
            empty = listeners.empty?
          }

          if empty
            clean_exceptions { nonblocking { @service_helper.unsubscribe_from(node,sub) } }
            @mutex.synchronized {
              @listeners.delete(node)
              @subscription.delete(node)
            }
          end
        end

        # subscription:: [Jabber::PubSub::Subscription]
        def unsubscribe(subscription)
          node = subscription.node
          subid = subscription.subid
          clean_exceptions { nonblocking { @service_helper.unsubscribe_from(node, subid) } }
          @mutex.synchronize {
            if @subscriptions[node] == subscription
              @subscriptions.delete(node)
              @listeners.delete(node)
            end
          }
        end

        #
        # Get all pubsub subscriptions currently registered for our
        # user on the XMPP server and add them to the list of
        # monitored subscriptions.  Return the new subscriptions as a
        # list.  Subscriptions that already exist in the monitored
        # list of subscriptions will not be duplicated and will not be
        # returned
        #
        # If node is nil, request subscriptions to all nodes,
        # otherwise just to the specified node.
        #
        def request_subscriptions(node = nil)
          list = nil
          if node.nil?
            list = clean_exceptions { nonblocking { @service_helper.get_subscriptions_from_all_nodes } }
          else
            list = clean_exceptions { nonblocking { @service_helper.get_subscriptions_from(node) } }
          end
          @mutex.synchronize {
            list.delete_if do |sub|
              @subscriptions.has_key?(sub.node) && @subscriptions[node].subid == sub.subid
            end
            list.each do |sub|
              if not @subscriptions.has_key?(sub.node)
                @subscriptions[sub.node] = sub
              end
            end
          }
          list
        end
      end # class Domain
    end # module PubSub
  end # module XMPP
end # module OMF

def run
  domain = "203.143.170.124"
  #domain = "10.42.54.2"

  n1 = "abc"

  puts "C1..."
  c1 = OMF::XMPP::Connection.new(domain, n1, "123")
  puts "done"
  c1.connect

  # First, for this test, unsubscribe from all existing subscriptions
  d2 = OMF::XMPP::PubSub::Domain.new(c1, domain)
  subs = d2.request_subscriptions
#  subs.each { |s| d2.unsubscribe(s) }

  sub = d2.listen_to_node("/OMF")
  sub2 = d2.listen_to_node("/OMF/foo")
  i = 1
  m = 0

  while true
    puts "sleep #{i}, messages: #{m}, queue: #{sub.queue.length}"
    sleep 1
    i += 1
    c1.ping

    item = Jabber::PubSub::Item.new
    hello = REXML::Element.new("hello")
    hello.add_text("Hello number #{i}!")
    item.add(hello)

    item2 = Jabber::PubSub::Item.new
    goodbye = REXML::Element.new("goodbye")
    goodbye.add_text("Goodbye #{m}")
    item2.add(goodbye)

    puts "Pub1"
    d2.publish_to_node("/OMF", item)
    puts "Pub2"
    d2.publish_to_node("/OMF/foo", item2)

    puts "Servicing queue 1"
    until sub.queue.empty?
      p sub.queue.pop.to_s
    end

    puts "Cleared first queue"
    until sub2.queue.empty?
      p sub2.queue.pop.to_s
    end

    puts "Cleared second queue"

    m += 1
  end
end

run if __FILE__ == $PROGRAM_NAME