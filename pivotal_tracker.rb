require 'rubygems'
require 'hpricot'
require 'net/https'
require 'uri'
require 'cgi'

##
# Pivotal Tracker API Ruby Wrapper
##

class Tracker
  VALID_STATES = ['unscheduled', 'unstarted', 'started', 'finished', 'delivered', 'accepted']
  
  def initialize(project_id = '123', token = '45a6a078f67d9210d2fba91f8c484e7b', ssl=true)
    @project_id, @token, @ssl = project_id, token, ssl
    protocol = @ssl ? 'https' : 'http'
    port     = @ssl ? '443'   : '80'
    @base_url = "#{protocol}://www.pivotaltracker.com:#{port}/services/v3/projects"
  end
  
  def project
    resource_uri = URI.parse("#{@base_url}/#{@project_id}")
   
    response = net_http(resource_uri).start do |http|
      http.get(resource_uri.path, {'X-TrackerToken' => @token})
    end
    validate_response(response.body, 'project')
    doc = Hpricot(response.body).at('project')
    { :name             => doc.at('name').innerHTML,
      :iteration_length => doc.at('iteration_length').innerHTML,
      :week_start_day   => doc.at('week_start_day').innerHTML,
      :point_scale      => doc.at('point_scale').innerHTML
    }
  end
  
  def stories
    resource_uri = URI.parse("#{@base_url}/#{@project_id}/stories")
    response = net_http(resource_uri).start do |http|
      http.get(resource_uri.path, {'X-TrackerToken' => @token})
    end
    validate_response(response.body, 'stories')
    
    doc = Hpricot(response.body)
    
    @stories = []
    
    doc.search('stories > story').each do |story|
      @stories << story_to_hash(story)
    end
    @stories
  end
  
  # would ideally like to pass a size, aka :all to limit search
  def find(filters = {})
    uri = "#{@base_url}/#{@project_id}/stories"
    unless filters.empty?
      uri << "?filter=" 
      filters.each do |key, value|
        uri << CGI::escape("#{key}:\"#{value}\"")
      end
    end
    
    resource_uri = URI.parse(uri)
    response = net_http(resource_uri).start do |http|
      http.get(resource_uri.path, {'X-TrackerToken' => @token})
    end
    validate_response(response.body, 'stories')
    
    doc = Hpricot(response.body)
    
    @stories = []
    
    doc.search('stories > story').each do |story|
      @stories << story_to_hash(story)
    end
    @stories
  end
  
  def find_story(id)
    resource_uri = URI.parse("#{@base_url}/#{@project_id}/stories/#{id}")
    response = net_http(resource_uri).start do |http|
      http.get(resource_uri.path, {'X-TrackerToken' => @token, 'Content-Type' => 'application/xml'})
    end
    validate_response(response.body, 'story')
    story_xml_to_hash(response.body)
  end
  
  def create_story(story)
    story_xml = build_story_xml(story)
    resource_uri = URI.parse("#{@base_url}/#{@project_id}/stories")
    response = net_http(resource_uri).start do |http|
      http.post(resource_uri.path, story_xml, {'X-TrackerToken' => @token, 'Content-Type' => 'application/xml'})
    end
    validate_response(response.body, 'story')
    story_xml_to_hash(response.body)
  end
  
  def update_story(story)
    story_xml = build_story_xml(story)
    resource_uri = URI.parse("#{@base_url}/#{@project_id}/stories/#{story[:id]}")
    response = net_http(resource_uri).start do |http|
      http.put(resource_uri.path, story_xml, {'X-TrackerToken' => @token, 'Content-Type' => 'application/xml'})
    end
    validate_response(response.body, 'story')
    story_xml_to_hash(response.body)
  end
  
  def delete_story(story_id)
    resource_uri = URI.parse("#{@base_url}/#{@project_id}/stories/#{story_id}")
    response = net_http(resource_uri).start do |http|
      http.delete(resource_uri.path, {'X-TrackerToken' => @token})
    end
    validate_response(response.body, 'story')
    story_id
  end
  
  def add_comment(story_id, text)
    resource_uri = URI.parse("#{@base_url}/#{@project_id}/stories/#{story_id}/notes")
    comment_xml = "<note><text>#{text}</text></note>"
    response = net_http(resource_uri).start do |http|
      http.post(resource_uri.path, comment_xml, {'X-TrackerToken' => @token, 'Content-Type' => 'application/xml'})
    end
    validate_response(response.body, 'note')
    doc = Hpricot(response.body).at('note')
    { :id     => doc.at('id').innerHTML.to_i,
      :text   => doc.at('text').innerHTML,
      :author => doc.at('author').innerHTML,
      :date   => doc.at('noted_at').innerHTML
    }
  end

  def update_state(story_id, new_state)
    story = find_story(story_id)
    raise TrackerException.new("No story with id: #{story_id}") unless story
    unless VALID_STATES.include?(new_state)
      raise TrackerException.new("Invalid state: #{new_state}.  Valid states are: #{VALID_STATES.join(', ')}")
    end
    story[:current_state] = new_state
    update_story(story)
  end
  
private
    
  def build_story_xml(story)
    story_xml = "<story>"
    story.each do |key, value|
      story_xml << "<#{key}>#{remove_xml_tags(value.to_s)}</#{key}>"
    end
    story_xml << "</story>"
  end

  def validate_response(body, response_root_element)
    response = Hpricot(body).at(response_root_element)
    if response == nil
      raise TrackerException.new("Expected response root element to be #{response_root_element}, got nil")
    elsif response.to_s.include? "<#{response_root_element}>"
      # success
    elsif (response/'errors'/'error') != nil
      raise TrackerException.new((response/'errors'/'error').innerHTML)
    end
  end

  def remove_xml_tags(xml)
    xml.gsub(/<\/?[^>]*>/, "")
  end

  def net_http(uri)
    h = Net::HTTP.new(uri.host, uri.port)
    h.use_ssl = @ssl
    h.verify_mode = OpenSSL::SSL::VERIFY_NONE
    h
  end

  def story_xml_to_hash(xml)
    doc = Hpricot(xml).at('story')
    story_to_hash(doc)
  end

  # Converts a story xml element to a hash. 
  #
  def story_to_hash(story)
    container_list_to_hash(story.containers)
  end
  
  # Converts a list of hpricot containers to either :key => value pairs or 
  # to :key => { ... } pairs, depending on whether elements are leaf nodes. 
  #
  def container_list_to_hash(containers)
    hash = {}
    containers.each do |container|      
      value = nil
      
      if container.empty? || container.containers.empty?
        # terminal element, add to hash
        value = cast(container['type'], container.innerHTML)
      else
        # recurse
        value = container_list_to_hash(container.containers)
      end

      name = container.name
      hash[name.to_sym] = value
    end
    
    hash
  end
  
  # Casts xml type to ruby type. 
  #
  def cast(type, value)
    case type
    when 'integer'
      Integer(value)
    else
      value
    end
  end
end

class TrackerException < Exception  
end
