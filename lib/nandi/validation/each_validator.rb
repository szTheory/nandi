# frozen_string_literal: true

module Nandi
  module Validation
    class DropIndexValidator
      def self.call(instruction)
        new(instruction).call
      end

      def initialize(instruction)
        @instruction = instruction
      end

      def call
        opts = instruction.extra_args

        opts.key?(:name) || opts.key?(:column)
      end

      attr_reader :instruction
    end

    class EachValidator
      def self.call(instruction)
        new(instruction).call
      end

      def initialize(instruction)
        @instruction = instruction
      end

      def call
        case instruction.procedure
        when :drop_index
          DropIndexValidator.call(instruction)
        when :add_column
          AddColumnValidator.call(instruction)
        else
          true
        end
      end

      attr_reader :instruction
    end
  end
end