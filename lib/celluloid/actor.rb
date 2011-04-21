module Celluloid
  # Actors are Celluloid's concurrency primitive. They're implemented as
  # normal Ruby objects wrapped in threads which communicate with asynchronous
  # messages. The implementation is inspired by Erlang's gen_server
  module Actor
    attr_reader :celluloid_mailbox
    
    # Methods added to classes which include Celluloid::Actor
    module ClassMethods
      # Retrieve the exit handler method for this class
      attr_reader :exit_handler
      
      # Create a new actor
      def spawn(*args, &block)
        actor = allocate
        actor.__initialize_actor(*args, &block)
        
        proxy = ActorProxy.new(actor)
        actor.instance_variable_set(:@celluloid_proxy, proxy) # FIXME: hax! :(
        proxy
      end
      
      # Trap errors from actors we're linked to when they exit
      def trap_exit(callback)
        @exit_handler = callback.to_sym
      end      
    end
    
    # Internal methods not intended as part of the public API
    module InternalMethods
      # Actor-specific initialization
      def __initialize_actor(*args, &block)
        @celluloid_mailbox = Mailbox.new
        @celluloid_links   = Links.new
              
        # Call the object's normal initialize method
        initialize(*args, &block)
      
        Thread.new { __run_actor }
      end
    
      # Run the actor
      def __run_actor
        Thread.current[:celluloid_mailbox] = @celluloid_mailbox
        __process_messages
      rescue Exception => ex
        __handle_crash(ex)
      end
    
      # Process incoming messages
      def __process_messages
        while true # instead of loop, for speed!
          begin
            call = @celluloid_mailbox.receive
          rescue ExitEvent => event
            __handle_exit(event)
            retry
          end
            
          call.dispatch(self)
        end
      end
      
      # Handle exit events received by this actor
      def __handle_exit(exit_event)
        exit_handler = self.class.exit_handler
        raise exit_event.reason unless exit_handler
        
        send exit_handler, exit_event.actor, exit_event.reason
      end
    
      # Handle any exceptions that occur within a running actor
      def __handle_crash(exception)
        @celluloid_mailbox.cleanup
        __log_error(exception)
        
        # Report the exit event to all actors we're linked to
        exit_event = ExitEvent.new(@celluloid_proxy, exception)
        
        # Propagate the error to all linked actors
        @celluloid_links.each do |actor|
          actor.celluloid_mailbox.system_event exit_event
        end
        
        Thread.current.exit
      rescue Exception => ex
        __log_error(ex)
      end
      
      # Log errors when an actor crashes
      # FIXME: This should probably thunk to a real logger
      def __log_error(ex)
        puts "!!! CRASH #{self.class}: #{ex.class}: #{ex.to_s}\n#{ex.backtrace.join("\n")}"
      end
    end
  
    def self.included(klass)
      klass.extend ClassMethods
      klass.send :include, InternalMethods
      klass.send :include, Linking
    end
  end
end