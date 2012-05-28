require 'rubygems'
require 'oml4r'
require 'log4r/outputter/outputter'

module OMF; module EC; module OML; end end end

module OMF::EC::OML
  
  # Send log messages to OML
  #
  class OMLOutputter < Log4r::Outputter
    include MonitorMixin
      
    def initialize(name = 'omllog', hash={})
      super(name, hash)
    end
        
    def canonical_log(event)
      LogMP.inject event.fullname, 
                    event.level,
                    Log4r::LNAMES[event.level],
                    event.data
                    event.tracer ? event.tracer : '-'
    end
    

  end # OMLOutputter
  
  # Define your own Measurement Point
  class LogMP < OML4R::MPBase
    name :log

    param :logger
    param :level, :type => :long
    param :level_name
    param :data
    param :tracer
  end
  
end # module
  