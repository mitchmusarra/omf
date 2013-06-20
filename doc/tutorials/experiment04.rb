#Welcome to Experiment 04
#This script allows experimenters to configure or address all resources within a defined group ane use simple substitutions

#Section 1
#Define otr2 application file-paths
#Define experiment parameters and measurement points
defApplication('otr2') do |app|
    
	#Application description and binary path
    app.binary_path = "/usr/bin/otr2"
    app.description = "otr is a configurable traffic sink that recieves packet streams"
    
    #Define configurable parameters of otr2
    app.defProperty('udp_local_host', 'IP address of this Destination node', '--udp:local_host', {:type => :string, :dynamic => false})
    app.defProperty('udp_local_port', 'Receiving Port of this Destination node', '--udp:local_port', {:type => :integer, :dynamic => false})
    app.defMeasurement('udp_in') do |m|
        m.defMetric('ts',:float)
        m.defMetric('flow_id',:long)
        m.defMetric('seq_no',:long)
        m.defMetric('pkt_length',:long)
        m.defMetric('dst_host',:string)
        m.defMetric('dst_port',:long)
    end
end

#Define otg2 application file-paths
#Define experiment parameters and measurement points
defApplication('otg2') do |app|
    
    #Application description and binary path
    app.binary_path = "/usr/bin/otg2"
    app.description = "otg is a configurable traffic generator that sends packet streams"
    
    #Define configurable parameters of otg2
    app.defProperty('generator', 'Type of packet generator to use (cbr or expo)', '-g', {:type => :string, :dynamic => false})
    app.defProperty('udp_broadcast', 'Broadcast', '--udp:broadcast', {:type => :integer, :dynamic => false})
    app.defProperty('udp_dst_host', 'IP address of the Destination', '--udp:dst_host', {:type => :string, :dynamic => false})
    app.defProperty('udp_dst_port', 'Destination Port to send to', '--udp:dst_port', {:type => :integer, :dynamic => false})
    app.defProperty('udp_local_host', 'IP address of this Source node', '--udp:local_host', {:type => :string, :dynamic => false})
    app.defProperty('udp_local_port', 'Local Port of this source node', '--udp:local_port', {:type => :integer, :dynamic => false})
    app.defProperty("cbr_size", "Size of packet [bytes]", '--cbr:size', {:dynamic => true, :type => :integer})
    app.defProperty("cbr_rate", "Data rate of the flow [kbps]", '--cbr:rate', {:dynamic => true, :type => :integer})
    app.defProperty("exp_size", "Size of packet [bytes]", '--exp:size', {:dynamic => true, :type => :integer})
    app.defProperty("exp_rate", "Data rate of the flow [kbps]", '--exp:rate', {:dynamic => true, :type => :integer})
    app.defProperty("exp_ontime", "Average length of burst [msec]", '--exp:ontime', {:dynamic => true, :type => :integer})
    app.defProperty("exp_offtime", "Average length of idle time [msec]", '--exp:offtime', {:dynamic => true, :type => :integer})
    
    #Define measurement points that application will output
    app.defMeasurement('udp_out') do |m|
        m.defMetric('ts',:float)
        m.defMetric('flow_id',:long)
        m.defMetric('seq_no',:long)
        m.defMetric('pkt_length',:long)
        m.defMetric('dst_host',:string)
        m.defMetric('dst_port',:long)
        
    end
end

#Section 2
#Define resources and nodes used by application
defGroup('Sender', "omf.nicta.node9") do |node|
    node.addApplication("otg2") do |app|
        app.setProperty('udp_local_host', '%net.w0.ip%')
        app.setProperty('udp_dst_host', '192.168.255.255')
        app.setProperty('udp_broadcast', 1)
        app.setProperty('udp_dst_port', 3000)
        app.measure('udp_out', :samples => 1)
    end
end

defGroup('Receiver', "omf.nicta.node10,omf.nicta.node11") do |node|
    node.addApplication("otr2") do |app|
        app.setProperty('udp_local_host', '192.168.255.255')
        app.setProperty('udp_local_port', 3000)
        app.measure('udp_in', :samples => 1)
    end
end

#Not implemented in OMF6 - New syntax required for experiment to work
allGroups.net.w0 do |interface|
    interface.mode = "adhoc"
    interface.type = 'g'
    interface.channel = "6"
    interface.essid = "Hello World! Experiment04"
    interface.ip = "192.168.0.%index%"
end

#Section 3
#Execution of application events
onEvent(:ALL_UP_AND_INSTALLED) do |event|
    after 10
    group("Receiver").startApplications
    after 15
    group("Sender").startApplications
    after 45
    group("Sender").stopApplications
    after 50
    group("Receiver").stopApplications
    Experiment.done
end
