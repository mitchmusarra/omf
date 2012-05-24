
require 'omf_common'
require 'erector'
require 'rack'
#require 'omf-web/page'
#require 'omf-web/multi_file'
require 'omf-web/session_store'
require 'omf-web/tab'

      
module OMF::Web::Rack      
  class TabMapper < MObject
    

    def initialize(opts = {})
      @opts = opts
      @tab_opts = opts[:tabs] || {}
      
      find_tabs()
    end
    
    def find_tabs()
      if (tabDirs = @opts[:tabDirs] || ["#{File.dirname(__FILE__)}/../tab"])
        tabDirs.each do |tabDir|
          if File.directory?(tabDir)
            Dir.foreach(tabDir) do |d| 
              if d =~ /^[a-z]/
                initF = "#{tabDir}/#{d}/init.rb"
                if File.readable?(initF)
                  MObject.debug(:web, "Loading tab '#{d}' (#{initF})")
                  load(initF)
                  # ctnt = File.read(initF)
                  # instance_eval(ctnt)
                end
              end
            end
          end
        end 
      end
      tabs = OMF::Web::Tab.selected_tabs(@opts[:use_tabs])
      @enabled_tabs = {} 
      tabs.each do |t| 
        name = t[:id]
        @enabled_tabs[name] = t  
      end 
      @opts[:tabs] = tabs
    end
    
    def call(env)
      req = ::Rack::Request.new(env)
      sessionID = req.params['sid']
      if sessionID.nil? || sessionID.empty?
        sessionID = "s#{(rand * 10000000).to_i}"
      end
      Thread.current["sessionID"] = sessionID
      
      body, headers = render_page(req)
      if headers.kind_of? String
        headers = {"Content-Type" => headers}
      end
      [200, headers, body] 
    end
    
    def _component_name(path)
      unless comp_name = path[1]
        comp_name = ((@opts[:tabs] || [])[0] || {})[:id]
      end
      comp_name = comp_name.to_sym if comp_name
      comp_name
    end
    
    def render_card(req)
      #puts ">>>> REQ: #{req.script_name}::#{req.inspect}"
      path = req.path_info.split('/')
      unless comp_name = _component_name(path)
        return render_no_card(req)
      end
      action = (path[2] || 'show').to_sym
      
      tab = @enabled_tabs[comp_name]
      unless tab
        warn "Request for unknown component '#{comp_name.inspect}':(#{@enabled_tabs.keys.inspect})"
        return render_unknown_card(comp_name, req)
      end
      
      opts = @opts.dup
      opts[:prefix] = req.script_name
      opts[:component_name] = comp_name.to_sym
      opts[:tab] = tab_id = tab[:id]
      #opts[:session_id] = session_id = req.params['sid']
      #opts[:update_path] = "/_update?id=#{session_id}:#{tab_id}"
      component = find_card_instance(tab, req)
      component.method(action).call(req, opts)
    end
    
    
    def find_card_instance(tab, req)
      sid = req.params['sid']
      tab_id = tab[:id]
      # topts = (OMF::Web::Tab.description_for(tab_id) || {})[:opts]
      # inst = OMF::Web::SessionStore[tab_id] ||= tab[:class].new(tab_id, topts || {})
      topts = (OMF::Web::Tab.description_for(tab_id) || {})[:opts]
      inst = OMF::Web::SessionStore[tab_id] ||= OMF::Web::Tab.create_tab(tab_id) #tab[:class].new(tab_id, topts || {})
    end
    
    def render_unknown_card(comp_name, req)
      popts = @opts.dup
      popts[:path] = req.path_info
      popts[:active_id] = 'unknown'
      popts[:flash] = {:alert => %{Unknonw component '#{comp_name}'. To select any of the available 
        components, please click on one of the tabs above.}}

      OMF::Web::Theme.require 'page'      
      [OMF::Web::Theme::Page.new(popts).to_html, 'text/html']
    end

    def render_no_card(req)
      popts = @opts.dup
      popts[:active_id] = 'unknown'
      popts[:body_text] = %{There are no components defined for this site.}
      popts[:card_title] = "Error: Missing component declaration"
      [Page.new(popts).to_html, 'text/html']
    end
   
    def render_page(req)
      render_card(req)
    end
  
  end # Tab Mapper
  
end # OMF:Common::Web2


      
        
