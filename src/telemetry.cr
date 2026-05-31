module Aptork
  alias TelemetryAttributes = Hash(String, String)

  class Telemetry
    def span(name : String, attributes : TelemetryAttributes = TelemetryAttributes.new, &block)
      yield
    end

    def counter(name : String, value : Int64 = 1_i64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
    end

    def histogram(name : String, value : Float64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
    end
  end

  class NoopTelemetry < Telemetry
  end
end
