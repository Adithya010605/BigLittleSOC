# Runs just before global routing (PRE_GLOBAL_ROUTE_TCL). The layer
# adjustment is otherwise set once, at floorplan, and stored in the design;
# setting it here also applies to a run resumed after CTS.
set_global_routing_layer_adjustment \
  $::env(MIN_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER) $::env(ROUTING_LAYER_ADJUSTMENT)
