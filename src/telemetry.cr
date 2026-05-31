module Aptok
  alias TelemetryAttributes = Hash(String, String)

  # Base telemetry interface. The default implementation is a no-op so that the
  # toolkit never depends on a metrics backend; applications can subclass it (see
  # `MetricsTelemetry`) or plug in an OpenTelemetry bridge of their own.
  class Telemetry
    def span(name : String, attributes : TelemetryAttributes = TelemetryAttributes.new, &block)
      yield
    end

    def counter(name : String, value : Int64 = 1_i64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
    end

    def histogram(name : String, value : Float64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
    end

    # Records the most recent value of a gauge (e.g. queue depth, connection
    # count). No-op by default, like the other recorders.
    def gauge(name : String, value : Float64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
    end
  end

  class NoopTelemetry < Telemetry
  end

  # A dependency-free, in-memory telemetry collector that aggregates counters,
  # gauges, histograms, and span timings. It can render the collected metrics in
  # the [OpenMetrics][openmetrics] / Prometheus text exposition format so an
  # application can expose a `/metrics` endpoint without pulling in an
  # OpenTelemetry SDK.
  #
  # [openmetrics]: https://github.com/OpenObservability/OpenMetrics
  #
  # ```
  # telemetry = Aptok::MetricsTelemetry.new
  # federation = Aptok::Federation.create("https://example.com", transport, telemetry: telemetry)
  # # ... handle some requests ...
  # puts telemetry.to_openmetrics
  # ```
  class MetricsTelemetry < Telemetry
    # Default histogram bucket upper bounds (in the unit of the recorded value;
    # for the toolkit's `*_ms` histograms this is milliseconds). Mirrors the
    # bucket layout commonly used for latency metrics.
    DEFAULT_BUCKETS = [
      1.0, 2.5, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 500.0,
      1_000.0, 2_500.0, 5_000.0, 10_000.0,
    ] of Float64

    record HistogramData,
      buckets : Array(Float64),
      counts : Array(Int64),
      sum : Float64,
      count : Int64

    @counters = Hash(String, Int64).new
    @gauges = Hash(String, Float64).new
    @histograms = Hash(String, HistogramData).new
    @labels = Hash(String, TelemetryAttributes).new
    @names = Hash(String, String).new

    def initialize(@buckets : Array(Float64) = DEFAULT_BUCKETS, @record_span_duration : Bool = true)
      @mutex = Mutex.new
    end

    def span(name : String, attributes : TelemetryAttributes = TelemetryAttributes.new, &block)
      counter("#{name}.spans", attributes: attributes)
      return yield unless @record_span_duration

      start = Time.monotonic
      begin
        yield
      ensure
        elapsed_ms = (Time.monotonic - start).total_milliseconds
        histogram("#{name}.duration_ms", elapsed_ms, attributes)
      end
    end

    def counter(name : String, value : Int64 = 1_i64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
      key = series_key(name, attributes)
      @mutex.synchronize do
        record_meta(key, name, attributes)
        @counters[key] = (@counters[key]? || 0_i64) + value
      end
    end

    def gauge(name : String, value : Float64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
      key = series_key(name, attributes)
      @mutex.synchronize do
        record_meta(key, name, attributes)
        @gauges[key] = value
      end
    end

    def histogram(name : String, value : Float64, attributes : TelemetryAttributes = TelemetryAttributes.new) : Nil
      key = series_key(name, attributes)
      @mutex.synchronize do
        record_meta(key, name, attributes)
        data = @histograms[key]? || HistogramData.new(
          @buckets,
          Array(Int64).new(@buckets.size, 0_i64),
          0.0,
          0_i64,
        )
        counts = data.counts.dup
        @buckets.each_with_index do |bound, index|
          counts[index] += 1 if value <= bound
        end
        @histograms[key] = HistogramData.new(@buckets, counts, data.sum + value, data.count + 1)
      end
    end

    # Returns the accumulated count for a counter series. Mainly for tests and
    # introspection.
    def counter_value(name : String, attributes : TelemetryAttributes = TelemetryAttributes.new) : Int64
      @mutex.synchronize { @counters[series_key(name, attributes)]? || 0_i64 }
    end

    def gauge_value(name : String, attributes : TelemetryAttributes = TelemetryAttributes.new) : Float64?
      @mutex.synchronize { @gauges[series_key(name, attributes)]? }
    end

    def histogram_data(name : String, attributes : TelemetryAttributes = TelemetryAttributes.new) : HistogramData?
      @mutex.synchronize { @histograms[series_key(name, attributes)]? }
    end

    def reset : Nil
      @mutex.synchronize do
        @counters.clear
        @gauges.clear
        @histograms.clear
        @labels.clear
        @names.clear
      end
    end

    # Renders all collected metrics in the OpenMetrics / Prometheus text
    # exposition format.
    def to_openmetrics : String
      @mutex.synchronize do
        String.build do |io|
          @counters.each do |key, value|
            io << metric_name(key) << "_total" << format_labels(key) << ' ' << value << '\n'
          end
          @gauges.each do |key, value|
            io << metric_name(key) << format_labels(key) << ' ' << format_float(value) << '\n'
          end
          @histograms.each do |key, data|
            name = metric_name(key)
            base_labels = @labels[key]? || TelemetryAttributes.new
            data.buckets.each_with_index do |bound, index|
              io << name << "_bucket" << format_labels_with(base_labels, "le", format_float(bound)) << ' ' << data.counts[index] << '\n'
            end
            io << name << "_bucket" << format_labels_with(base_labels, "le", "+Inf") << ' ' << data.count << '\n'
            io << name << "_sum" << format_labels(key) << ' ' << format_float(data.sum) << '\n'
            io << name << "_count" << format_labels(key) << ' ' << data.count << '\n'
          end
        end
      end
    end

    # Alias for `to_openmetrics`; the Prometheus text format is a subset.
    def to_prometheus : String
      to_openmetrics
    end

    private def series_key(name : String, attributes : TelemetryAttributes) : String
      sanitized = sanitize_name(name)
      label_part = attributes.to_a.sort_by(&.[0]).map { |label, value| "#{label}=#{value}" }.join(',')
      label_part.empty? ? sanitized : "#{sanitized} #{label_part}"
    end

    # Must be called while holding @mutex.
    private def record_meta(key : String, name : String, attributes : TelemetryAttributes) : Nil
      @names[key] = sanitize_name(name)
      @labels[key] = attributes
    end

    private def metric_name(key : String) : String
      @names[key]? || key.split(' ', 2).first
    end

    private def format_labels(key : String) : String
      labels = @labels[key]?
      return "" unless labels && !labels.empty?

      format_labels_with(labels, nil, nil)
    end

    private def format_labels_with(labels : TelemetryAttributes, extra_key : String?, extra_value : String?) : String
      pairs = labels.to_a.sort_by(&.[0]).map { |label, value| "#{sanitize_name(label)}=\"#{escape_label(value)}\"" }
      pairs << "#{extra_key}=\"#{escape_label(extra_value.to_s)}\"" if extra_key
      return "" if pairs.empty?

      "{#{pairs.join(",")}}"
    end

    private def sanitize_name(name : String) : String
      name.gsub(/[^a-zA-Z0-9_:]/, "_")
    end

    private def escape_label(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n")
    end

    private def format_float(value : Float64) : String
      if value == value.to_i64 && value.abs < 1e15
        value.to_i64.to_s
      else
        value.to_s
      end
    end
  end
end
