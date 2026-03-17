-record(handler, {
    id :: telemetry:handler_id(),
    event_name :: telemetry:event_name(),
    function :: telemetry:handler_function(),
    config :: telemetry:handler_config()
}).
