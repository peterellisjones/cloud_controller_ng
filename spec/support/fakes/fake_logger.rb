module VCAP::CloudController
  FakeLogger = Struct.new(:log_messages) do
    def info(message, _)
      log_messages << message
    end
  end
end
