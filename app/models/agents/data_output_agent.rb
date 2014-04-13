module Agents
  class DataOutputAgent < Agent
    cannot_be_scheduled!

    description  do
      <<-MD
        The Agent outputs received events as either RSS or JSON.  Use it to output a public or private stream of Huginn data.

        This Agent will output data at:

        `https://#{ENV['DOMAIN']}/users/#{user.id}/web_requests/#{id || '<id>'}/:secret.xml`

        where `:secret` is one of the allowed secrets specified in your options and the extension can be `xml` or `json`.

        You can setup multiple secrets so that you can individually authorize external systems to
        access your Huginn data.

        Options:

          * `secrets` - An array of tokens that the requestor must provide for light-weight authentication.
          * `expected_receive_period_in_days` - How often you expect data to be received by this Agent from other Agents.
          * `template` - A JSON object representing a mapping between item output keys and incoming event JSONPath values.  JSONPath values must start with `$`, or can be interpolated between `<` and `>` characters.  The `item` key will be repeated for every Event.
      MD
    end

    def default_options
      {
        "secrets" => ["a-secret-key"],
        "expected_receive_period_in_days" => 2,
        "template" => {
          "title" => "XKCD comics as a feed",
          "description" => "This is a feed of recent XKCD comics, generated by Huginn",
          "item" => {
            "title" => "$.title",
            "description" => "Secret hovertext: <$.hovertext>",
            "link" => "$.url",
          }
        }
      }
    end

    #"guid" => "",
    #  "pubDate" => ""

    def working?
      last_receive_at && last_receive_at > options['expected_receive_period_in_days'].to_i.days.ago && !recent_error_logs?
    end

    def validate_options
      unless options['secrets'].is_a?(Array) && options['secrets'].length > 0
        errors.add(:base, "Please specify one or more secrets for 'authenticating' incoming feed requests")
      end
      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end

      unless options['template'].present? && options['template']['item'].present? && options['template']['item'].is_a?(Hash)
        errors.add(:base, "Please provide template and template.item")
      end
    end

    def events_to_show
      (options['events_to_show'].presence || 40).to_i
    end

    def feed_ttl
      (options['ttl'].presence || 60).to_i
    end

    def feed_title
      options['template']['title'].presence || "#{name} Event Feed"
    end

    def feed_description
      options['template']['description'].presence || "A feed of Events received by the '#{name}' Huginn Agent"
    end

    def receive_web_request(params, method, format)
      if options['secrets'].include?(params['secret'])
        items = received_events.order('id desc').limit(events_to_show).map do |event|
          interpolated = Utils.recursively_interpolate_jsonpaths(options['template']['item'], event.payload, :leading_dollarsign_is_jsonpath => true)
          interpolated['guid'] = event.id
          interpolated['pubDate'] = event.created_at.rfc2822.to_s
          interpolated
        end

        if format =~ /json/
          content = {
            'title' => feed_title,
            'description' => feed_description,
            'pubDate' => Time.now,
            'items' => items
          }

          return [content, 200]
        else
          content = Utils.unindent(<<-XML)
            <?xml version="1.0" encoding="UTF-8" ?>
            <rss version="2.0">
            <channel>
             <title>#{feed_title.encode(:xml => :text)}</title>
             <description>#{feed_description.encode(:xml => :text)}</description>
             <lastBuildDate>#{Time.now.rfc2822.to_s.encode(:xml => :text)}</lastBuildDate>
             <pubDate>#{Time.now.rfc2822.to_s.encode(:xml => :text)}</pubDate>
             <ttl>#{feed_ttl}</ttl>

          XML

          content += items.to_xml(:skip_types => true, :root => "items", :skip_instruct => true, :indent => 1).gsub(/^<\/?items>/, '').strip

          content += Utils.unindent(<<-XML)
            </channel>
            </rss>
          XML

          return [content, 200, 'text/xml']
        end
      else
        if format =~ /json/
          return [{ :error => "Not Authorized" }, 401]
        else
          return ["Not Authorized", 401]
        end
      end
    end
  end
end
