%% Shared LB latency-shedding thresholds (spec native-distribution
%% Part B): the pure local `degraded_filter', the remote latency
%% post-filter, the publish coalescer, and the eunit suites all read
%% these so local and fleet semantics can never drift.
-ifndef(JANUS_LB_HRL).
-define(JANUS_LB_HRL, true).

%% A route needs at least this many EWMA samples before any shedding
%% verdict (local or remote) may name it.
-define(EWMA_MIN_SAMPLES, 4).
%% EWMA rows older than this are stale = no local evidence.
-define(EWMA_STALE_MS, 600000).
%% Fleet latency signal TTL (receiver decays the row on its own clock).
-define(FLEET_LAT_TTL_MS, 15000).
%% Coalesced degraded heartbeat while a route is locally degraded.
-define(FLEET_HEARTBEAT_MS, 5000).
%% Egress TTL clamp for cooldown-family signals (bounded re-learning tax).
-define(FLEET_COOL_CAP_MS, 30000).
%% Distinct live senders required before a remote degraded verdict may
%% shed a candidate (single-sender sickness never sheds fleet-wide).
-define(REMOTE_LAT_QUORUM, 2).

-endif.
