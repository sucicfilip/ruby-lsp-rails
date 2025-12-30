# typed: strict
# frozen_string_literal: true

module RubyLsp
  module Rails
    # ![Definition demo](../../definition.gif)
    #
    # The [definition
    # request](https://microsoft.github.io/language-server-protocol/specification#textDocument_definition) jumps to the
    # definition of the symbol under the cursor.
    #
    # Currently supported targets:
    #
    # - Callbacks
    # - Named routes (e.g. `users_path`)
    #
    # # Example
    #
    # ```ruby
    # before_action :foo # <- Go to definition on this symbol will jump to the method
    # ```
    #
    # Notes for named routes:
    #
    # - It is available only in Rails 7.1 or newer.
    # - Route may be defined across multiple files, e.g. using `draw`, rather than in `routes.rb`.
    # - Routes won't be found if not defined for the Rails development environment.
    # - If using `constraints`, the route can only be found if the constraints are met.
    # - Changes to routes won't be picked up until the server is restarted.
    class Definition
      include Requests::Support::Common

      #: (RunnerClient client, RubyLsp::ResponseBuilders::CollectionResponseBuilder[(Interface::Location | Interface::LocationLink)] response_builder, NodeContext node_context, RubyIndexer::Index index, Prism::Dispatcher dispatcher) -> void
      def initialize(client, response_builder, node_context, index, uri, dispatcher)
        @client = client
        @response_builder = response_builder
        @node_context = node_context
        @nesting = node_context.nesting #: Array[String]
        @index = index
        @uri = uri

        dispatcher.register(self, :on_call_node_enter, :on_symbol_node_enter, :on_string_node_enter)
      end

      #: (Prism::SymbolNode node) -> void
      def on_symbol_node_enter(node)
        handle_possible_dsl(node)
      end

      #: (Prism::StringNode node) -> void
      def on_string_node_enter(node)
        handle_possible_dsl(node)
      end

      #: (Prism::CallNode node) -> void
      def on_call_node_enter(node)
        return unless self_receiver?(node)

        message = node.message

        return unless message

        if message.end_with?("_path") || message.end_with?("_url")
          handle_route(node)
        end
      end

      private

      #: ((Prism::SymbolNode | Prism::StringNode) node) -> void
      def handle_possible_dsl(node)
        call_node = @node_context.call_node
        return unless call_node
        return unless self_receiver?(call_node)

        message = call_node.message

        return unless message

        arguments = call_node.arguments&.arguments
        return unless arguments

        if Support::Associations::ALL.include?(message)
          handle_association(call_node)
        elsif Support::Callbacks::ALL.include?(message)
          handle_callback(node, call_node, arguments)
          handle_if_unless_conditional(node, call_node, arguments)
        elsif Support::Validations::ALL.include?(message)
          handle_validation(node, call_node, arguments)
          handle_if_unless_conditional(node, call_node, arguments)
        elsif Support::Routes::ALL.include?(message)
          handle_controller_action(node)
        end
      end

      #: ((Prism::SymbolNode | Prism::StringNode) node, Prism::CallNode call_node, Array[Prism::Node] arguments) -> void
      def handle_callback(node, call_node, arguments)
        focus_argument = arguments.find { |argument| argument == node }

        name = case focus_argument
        when Prism::SymbolNode
          focus_argument.value
        when Prism::StringNode
          focus_argument.content
        end

        return unless name

        collect_definitions(name)
      end

      #: ((Prism::SymbolNode | Prism::StringNode) node, Prism::CallNode call_node, Array[Prism::Node] arguments) -> void
      def handle_validation(node, call_node, arguments)
        message = call_node.message
        return unless message

        focus_argument = arguments.find { |argument| argument == node }
        return unless focus_argument

        return unless node.is_a?(Prism::SymbolNode)

        name = node.value
        return unless name

        # validates_with uses constants, not symbols - skip (handled by constant resolution)
        return if message == "validates_with"

        collect_definitions(name)
      end

      #: ((Prism::SymbolNode | Prism::StringNode) node) -> void
      def handle_controller_action(node)
        return unless @uri.path.match?(Support::Routes::ROUTE_FILES_PATTERN)
        return unless node.is_a?(Prism::StringNode)

        content = node.content
        return unless content.include?("#")

        controller, action = content.split("#", 2)

        parent_call_node = find_parent_call_node(node)
        scopes = collect_scopes(parent_call_node, node)

        results = @client.controller_action_target(
          controller: (scopes + [controller]).join("/"),
          action: action,
        )

        return unless results&.any?

        results.each do |result|
          @response_builder << Support::LocationBuilder.line_location_from_s(result.fetch(:location))
        end
      end

      def find_parent_call_node(target_node)
        statements_node =
          @node_context
            .instance_variable_get(:@nesting_nodes)
            .second
            .child_nodes
            .second

        return nil unless statements_node.is_a?(Prism::StatementsNode)

        statements_node.body.each do |child|
          next unless child.is_a?(Prism::CallNode)
          next unless node_contains?(child, target_node)

          return child
        end

        nil
      end

      def node_contains?(current_node, target_node)
        return true if current_node.equal?(target_node)

        current_node&.child_nodes&.any? do |child|
          node_contains?(child, target_node)
        end
      end

      def collect_scopes(current_node, node, result = [])
        return result if current_node.equal?(node)
        return result unless current_node.respond_to?(:child_nodes)

        extract_scope_or_namespace(current_node, result)

        current_node.child_nodes.each do |child|
          collect_scopes(child, result)
        end

        result
      end

      def extract_scope_or_namespace(node, result)
        return unless node.is_a?(Prism::CallNode)

        case node.name
        when :scope
          extract_scope(node, result)
        when :namespace
          extract_namespace(node, result)
        end
      end

      def extract_scope(call_node, result)
        args = call_node.arguments
        return unless args

        keyword_hash = args.arguments.find { |a| a.is_a?(Prism::KeywordHashNode) }
        return unless keyword_hash

        keyword_hash.elements.each do |assoc|
          next unless assoc.key.is_a?(Prism::SymbolNode)
          next unless ["module", "namespace"].include?(assoc.key.unescaped)
          next unless assoc.value.is_a?(Prism::StringNode)

          result << assoc.value.unescaped
        end
      end

      def extract_namespace(call_node, result)
        args = call_node.arguments
        return unless args
        return if args.arguments.empty?

        first_arg = args.arguments.first
        return unless first_arg.is_a?(Prism::StringNode)

        result << first_arg.unescaped
      end

      #: (Prism::CallNode node) -> void
      def handle_association(node)
        first_argument = node.arguments&.arguments&.first
        return unless first_argument.is_a?(Prism::SymbolNode)

        association_name = first_argument.unescaped

        result = @client.association_target(
          model_name: @nesting.join("::"),
          association_name: association_name,
        )

        return unless result

        @response_builder << Support::LocationBuilder.line_location_from_s(result.fetch(:location))
      end

      #: (Prism::CallNode node) -> void
      def handle_route(node)
        result = @client.route_location(
          node.message, #: as !nil
        )
        return unless result

        @response_builder << Support::LocationBuilder.line_location_from_s(result.fetch(:location))
      end

      #: (String name) -> void
      def collect_definitions(name)
        methods = @index.resolve_method(name, @nesting.join("::"))
        return unless methods

        methods.each do |target_method|
          @response_builder << Interface::Location.new(
            uri: target_method.uri.to_s,
            range: range_from_location(target_method.location),
          )
        end
      end

      #: ((Prism::SymbolNode | Prism::StringNode) node, Prism::CallNode call_node, Array[Prism::Node] arguments) -> void
      def handle_if_unless_conditional(node, call_node, arguments)
        keyword_arguments = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) } #: as Prism::KeywordHashNode?
        return unless keyword_arguments

        element = keyword_arguments.elements.find do |element|
          next false unless element.is_a?(Prism::AssocNode)

          key = element.key
          next false unless key.is_a?(Prism::SymbolNode)

          key_value = key.value
          next false unless key_value == "if" || key_value == "unless"

          value = element.value
          next false unless value.is_a?(Prism::SymbolNode)

          value == node
        end #: as Prism::AssocNode?

        return unless element

        value = element.value #: as Prism::SymbolNode
        method_name = value.value

        return unless method_name

        collect_definitions(method_name)
      end
    end
  end
end
