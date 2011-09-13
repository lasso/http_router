class HttpRouter
  class Node
    class Path < Node
      attr_reader :route, :param_names, :dynamic, :path
      alias_method :dynamic?, :dynamic
      def initialize(router, parent, route, path, param_names = [])
        @route, @path, @param_names, @dynamic = route, path, param_names, !param_names.empty?
        @route.add_path(self)
        raise AmbiguousVariableException, "You have duplicate variable name present: #{param_names.join(', ')}" if param_names.uniq.size != param_names.size
        super router, parent
        router.uncompile
      end

      def hashify_params(params)
        @dynamic && params ? Hash[param_names.zip(params)] : {}
      end

      def to_code
        path_ivar = inject_root_ivar(self)
        "#{"if request.path_finished?" unless route.match_partially}
          catch(:pass) do
            #{"if request.path.size == 1 && request.path.first == '' && (request.rack_request.head? || request.rack_request.get?) && request.rack_request.path_info[-1] == ?/
              response = ::Rack::Response.new
              response.redirect(request.rack_request.path_info[0, request.rack_request.path_info.size - 1], 302)
              throw :success, response.finish
            end" if router.redirect_trailing_slash?}

            #{"if request.path.empty?#{" or (request.path.size == 1 and request.path.first == '')" if router.ignore_trailing_slash?}" unless route.match_partially}
              if request.perform_call
                env = request.rack_request.dup.env
                env['router.request'] = request
                env['router.params'] ||= {}
                #{"env['router.params'].merge!(Hash[#{param_names.inspect}.zip(request.params)])" if dynamic?}
                @router.rewrite#{"_partial" if route.match_partially}_path_info(env, request)
                response = @router.process_destination_path(#{path_ivar}, env)
                router.pass_on_response(response) ? throw(:pass) : throw(:success, response)
              else
                request.matched_route(Response.new(request, #{path_ivar}))
              end
            #{"end" unless route.match_partially}
          end
        #{"end" unless route.match_partially}"
      end

      def usable?(other)
        other == self
      end

      def inspect_label
        "Path: #{path.inspect} for route #{route.name || 'unnamed route'} to #{route.dest.inspect}"
      end
    end
  end
end