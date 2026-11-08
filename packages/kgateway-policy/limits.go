package main

import (
	"container/list"
	"errors"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	extproc "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
)

// Units and first-request behavior follow nginx 1.27.1 limit_req: rate and
// excess are thousandths of a request, with integer millisecond decay. Rejected
// requests do not commit debt. State is local to one proxy, as with nginx zones.
type clientState struct {
	key    string
	last   time.Time
	excess [2]int64
	active int
}
type requestLimits struct {
	mu                   sync.Mutex
	states               map[string]*list.Element
	lru                  list.List
	rates                [2]int64
	bursts               [2]int64
	concurrent, capacity int
}

func newRequestLimits(rps, rpm, concurrent, capacity int) (*requestLimits, error) {
	if rps < 1 || rps > 100000 || rpm < 1 || rpm > 10000000 || concurrent < 1 || concurrent > 10000 || capacity < 1 || capacity > 65536 {
		return nil, errors.New("invalid request limits")
	}
	return &requestLimits{states: make(map[string]*list.Element), rates: [2]int64{int64(rps) * 1000, int64(rpm) * 1000 / 60}, bursts: [2]int64{int64(rps) * 3000, int64(rpm) * 3000}, concurrent: concurrent, capacity: capacity}, nil
}

func debt(excess, rate, ms int64) int64 {
	if ms < 0 {
		ms = 0
	}
	// Avoid overflow after a long idle period. Every configured bucket is fully
	// drained after this bound; active requests still retain their identity slot.
	if ms > 86400000 {
		return 0
	}
	value := excess - rate*ms/1000
	if value < 0 {
		return 0
	}
	return value
}

// acquire returns a release closure only after both buckets and concurrency
// accept. Caller must release exactly once when Envoy closes this request's
// processor RPC; trailer SEND with body NONE is a required deployment setting.
func (l *requestLimits) acquire(key string, now time.Time) (func(), bool) {
	// nginx stores its clock as integer milliseconds. Quantize before storing
	// last, otherwise truncating each elapsed interval loses fractional decay.
	now = now.Truncate(time.Millisecond)
	l.mu.Lock()
	item := l.states[key]
	if item == nil {
		if len(l.states) >= l.capacity {
			// Evict only a fully drained, inactive oldest identity. Otherwise reject
			// new identities instead of forgetting an active client's limits.
			oldest := l.lru.Back()
			if oldest == nil {
				l.mu.Unlock()
				return nil, false
			}
			state := oldest.Value.(*clientState)
			ms := now.Sub(state.last).Milliseconds()
			if state.active != 0 || debt(state.excess[0], l.rates[0], ms) != 0 || debt(state.excess[1], l.rates[1], ms) != 0 {
				l.mu.Unlock()
				return nil, false
			}
			delete(l.states, state.key)
			l.lru.Remove(oldest)
		}
		state := &clientState{key: key, last: now}
		item = l.lru.PushFront(state)
		l.states[key] = item
	} else {
		state := item.Value.(*clientState)
		if state.active >= l.concurrent {
			l.mu.Unlock()
			return nil, false
		}
		ms := now.Sub(state.last).Milliseconds()
		var proposed [2]int64
		for i := range proposed {
			// nginx subtracts decay before adding the next thousandth-unit request.
			proposed[i] = state.excess[i] - l.rates[i]*max(0, min(ms, int64(86400000)))/1000 + 1000
			if proposed[i] < 0 {
				proposed[i] = 0
			}
			if proposed[i] > l.bursts[i] {
				l.mu.Unlock()
				return nil, false
			}
		}
		state.excess = proposed
		state.last = now
		l.lru.MoveToFront(item)
	}
	state := item.Value.(*clientState)
	state.active++
	l.mu.Unlock()
	var once sync.Once
	return func() { once.Do(func() { l.mu.Lock(); state.active--; l.mu.Unlock() }) }, true
}

func clientKey(message *extproc.ProcessingRequest) (string, bool) {
	// This attribute is supplied by Envoy's original-IP detector, not read from
	// arbitrary XFF/CF/request headers. Listener trust still needs network proof.
	address := message.GetAttributes()["envoy.filters.http.ext_proc"].GetFields()["source.address"].GetStringValue()
	ip, err := netip.ParseAddr(address)
	if err != nil {
		endpoint, endpointErr := netip.ParseAddrPort(address)
		if endpointErr != nil {
			return "", false
		}
		ip = endpoint.Addr()
	}
	if ip.Zone() != "" {
		return "", false
	}
	host, ok := header(message.GetRequestHeaders().GetHeaders(), ":authority")
	if !ok || host == "" || len(host) > 253 || strings.ContainsAny(host, "\x00\r\n") {
		return "", false
	}
	// Host ports and a terminal DNS dot must not create fresh rate identities
	// for the same HTTPRoute hostname. IP-literal authorities are unsupported
	// by this DNS-host candidate and fail closed.
	if strings.Contains(host, ":") {
		name, port, found := strings.Cut(host, ":")
		numeric, e := strconv.Atoi(port)
		if !found || e != nil || numeric < 1 || numeric > 65535 || strings.Contains(port, ":") {
			return "", false
		}
		host = name
	}
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if host == "" {
		return "", false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) < 1 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return "", false
			}
		}
	}
	return host + "\x00" + ip.Unmap().String(), true
}
