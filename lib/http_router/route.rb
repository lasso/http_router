class HttpRouter
  class Route
    attr_reader :default_values, :matches_with, :router, :path, :conditions

    def initialize(router, path, opts = {})
      @router = router
      @original_path = path
      @opts = opts
      @matches_with = {}
      @default_values = opts[:default_values] || {}
      if @original_path[-1] == ?*
        @match_partially = true
        path.slice!(-1)
      end
      process_opts
    end

    def process_opts
      @arbitrary = @opts[:arbitrary] || @opts[:__arbitrary__]
      @conditions = @opts[:conditions] || @opts[:__conditions__] || {}
      @opts.merge!(@opts[:matching]) if @opts[:matching]
      @match_partially = @opts[:partial] if @match_partially.nil? && @opts.key?(:partial)
      name(@opts[:name]) if @opts.key?(:name)
    end

    def as_options
      {:matching => @matches_with, :conditions => @conditions, :default_values => @default_values, :name => @name, :partial => @partially_match, :arbitrary => @arbitrary}
    end

    def partial(match_partially = true)
      @match_partially = match_partially
      self
    end

    def match_partially?
      @match_partially
    end

    def dest
      @app
    end

    def regex?
      false
    end

    def to(dest = nil, &dest2)
      @app = dest || dest2
      compile
      self
    end

    def compiled?
      @compiled
    end

    def name(n)
      @name = n
      @router.named_routes[n] = self
      self
    end

    def request_method(m)
      ((@conditions ||= {})[:request_method] ||= []) << m; self
    end

    def host(host)
      ((@conditions ||= {})[:host] ||= []) << host; self
    end

    def scheme(scheme)
      ((@conditions ||= {})[:scheme] ||= []) << scheme; self
    end

    def user_agent(user_agent)
      ((@conditions ||= {})[:user_agent] ||= []) << user_agent; self
    end

    def matching(matchers)
      matchers = Hash[*matchers] if matchers.is_a?(Array)
      @opts.merge!(matchers)
      self
    end

    def default(defaults)
      (@default_values ||= {}).merge!(defaults)
      self
    end

    # Sets the destination of this route to redirect to an arbitrary URL.
    def redirect(path, status = 302)
      raise ArgumentError, "Status has to be an integer between 300 and 399" unless (300..399).include?(status)
      to { |env|
        params = env['router.params']
        response = ::Rack::Response.new
        response.redirect(eval(%|"#{path}"|), status)
        response.finish
      }
      self
    end

    # Sets the destination of this route to serve static files from either a directory or a single file.
    def static(root)
      if File.directory?(root)
        partial.to ::Rack::File.new(root)
      else
        to {|env| env['PATH_INFO'] = File.basename(root); ::Rack::File.new(File.dirname(root)).call(env) }
      end
      self
    end

    def post;    request_method('POST');    end
    def get;     request_method('GET');     end
    def put;     request_method('PUT');     end
    def delete;  request_method('DELETE');  end
    def head;    request_method('HEAD');    end
    def options; request_method('OPTIONS'); end
    def patch;   request_method('PATCH'); end

    def arbitrary(blk = nil, &blk2)
      arbitrary_with_continue { |req, params|
        req.continue[(blk || blk2)[req, params]]
      }
    end

    def arbitrary_with_continue(blk = nil, &blk2)
      (@arbitrary ||= []) << (blk || blk2)
      self
    end

    def url(*args)
      result, extra_params = url_with_params(*args)
      append_querystring(result, extra_params)
    end

    def clone(new_router)
      Route.new(new_router, @original_path.dup, as_options)
    end

    def url_with_params(*args)
      options = args.last.is_a?(Hash) ? args.pop : nil
      options = options.nil? ? default_values.dup : default_values.merge(options) if default_values
      options.delete_if{ |k,v| v.nil? } if options
      path = if args.empty?
        matching_path(options)
      else
        matching_path(args, options)
      end
      raise InvalidRouteException unless path
      result, params = path.url(args, options)
      mount_point = router.url_mount && router.url_mount.url(options)
      mount_point ? [File.join(mount_point, result), params] : [result, params]
    end

    def significant_variable_names
      @significant_variable_names ||= @original_path.scan(/(^|[^\\])[:\*]([a-zA-Z0-9_]+)/).map{|p| p.last.to_sym}
    end

    def matching_path(params, other_hash = nil)
      if @paths.size == 1
        @paths.first
      else
        if params.is_a?(Array)
          significant_keys = other_hash && significant_variable_names & other_hash.keys
          @paths.find { |path|
            var_count = significant_keys ? params.size + significant_keys.size : params.size
            path.param_names.size == var_count
          }
        else
          @paths.each do |path|
            if params && !params.empty?
              return path if (path.param_names & params.keys).size == path.param_names.size
            elsif path.param_names.empty?
              return path
            end
          end
          nil
        end
      end
    end

    def named
      @name
    end

    def to_s
      "#<HttpRouter:Route #{object_id} @original_path=#{@original_path.inspect} @conditions=#{@conditions.inspect} @arbitrary=#{@arbitrary.inspect}>"
    end

    def compile
      return if @compiled
      start_index, end_index = 0, 1
      raw_paths, chars = [""], @original_path.split('')
      until chars.empty?
      case fc = chars.first[0]
        when ?(
          chars.shift
          (start_index...end_index).each { |path_index| raw_paths << raw_paths[path_index].dup }
          start_index = end_index
          end_index = raw_paths.size
        when ?)
          chars.shift
          start_index -= end_index - start_index
        else
          c = if chars[0][0] == ?\\ && (chars[1][0] == ?( || chars[1][0] == ?)); chars.shift; chars.shift; else; chars.shift; end
          (start_index...end_index).each { |path_index| raw_paths[path_index] << c } 
        end
      end
      raw_paths.reverse!
      @paths = raw_paths.map do |path|
        param_names = []
        node = @router.root
        path.split(/\//).each do |part|
          next if part == ''
          parts = part.scan(/\\.|[:*][a-z0-9_]+|[^:*\\]+/)
          if parts.size == 1
            name = part[1, part.size]
            node = case parts[0][0]
            when ?\\
              node.add_lookup(parts[0][1].chr)
            when ?:
              param_names << name.to_sym
              matches_with[name.to_sym] = @opts[name.to_sym]
              @opts[name.to_sym] ? node.add_spanning_match(@opts.delete(name.to_sym)) : node.add_variable
            when ?*
              param_names << name.to_sym
              matches_with[name.to_sym] = @opts[name.to_sym]
              @opts[name.to_sym] ? node.add_glob_regexp(@opts.delete(name.to_sym)) : node.add_glob
            else
              node.add_lookup(parts[0])
            end
          else
            capturing_indicies = []
            splitting_indicies = []
            captures = 0
            spans = false
            regex = parts.inject('') do |reg, part|
              reg << case part[0]
              when ?\\
                Regexp.quote(part[1].chr)
              when ?:
                captures += 1
                capturing_indicies << captures
                name = part[1, part.size].to_sym
                param_names << name
                matches_with[name] = @opts[name]
                "(#{(@opts[name] || '[^/]*?')})"
              when ?*
                spans = true
                captures += 1
                splitting_indicies << captures
                name = part[1, part.size].to_sym
                param_names << name
                matches_with[name] = @opts[name]
                @opts[name] ?
                  "((?:#{@opts[name]}\\/?)+)" : '(.*?)'
              else
                Regexp.quote(part)
              end
            end
            node = spans ? node.add_spanning_match(Regexp.new("#{regex}$"), capturing_indicies, splitting_indicies) :
              node.add_match(Regexp.new("#{regex}$"), capturing_indicies, splitting_indicies)
          end
        end
        add_non_path_to_tree(node, path, param_names)
      end
      @compiled = true
      self
    end

    private
    def add_non_path_to_tree(node, path, names)
      path_obj = Path.new(self, path, names)
      node = node.add_request(@conditions) unless @conditions.empty?
      @arbitrary.each{|a| node = node.add_arbitrary(a, match_partially?, names)} if @arbitrary
      node.add_destination(path_obj, @match_partially)
      if dest.respond_to?(:url_mount=)
        urlmount = UrlMount.new(@original_path, @default_values)
        urlmount.url_mount = router.url_mount if router.url_mount
        dest.url_mount = urlmount
      end
      path_obj
    end

    def append_querystring_value(uri, key, value)
      case value
      when Array
        k = "#{key}[]"
        value.each{ |v| append_querystring_value(uri, k, v) }
      when Hash
        value.each{ |k, v| append_querystring_value(uri, "#{key}[#{k}]", v) }
      else
        uri << '&' << CGI.escape(key.to_s) << '=' << CGI.escape(value.to_s)
      end
    end

    def append_querystring(uri, params)
      if params && !params.empty?
        uri_size = uri.size
        params.each{ |k,v|  append_querystring_value(uri, k, v) }
        uri[uri_size] = ??
      end
      uri
    end
  end
end