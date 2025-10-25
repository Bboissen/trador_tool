package ratelimit

import (
	"sync"
	"time"
)

type Limiter struct {
	rps   float64
	burst float64
	store sync.Map
}

type bucket struct {
	mu       sync.Mutex
	tokens   float64
	last     time.Time
	rps      float64
	capacity float64
}

func New(rps float64, burst int) *Limiter {
	if rps <= 0 {
		rps = 1
	}
	if burst <= 0 {
		burst = 1
	}
	return &Limiter{
		rps:   rps,
		burst: float64(burst),
	}
}

func (l *Limiter) Allow(key string) bool {
	if l == nil {
		return true
	}
	b := l.getBucket(key)
	b.mu.Lock()
	defer b.mu.Unlock()

	now := time.Now()
	elapsed := now.Sub(b.last).Seconds()
	b.last = now

	b.tokens += elapsed * b.rps
	if b.tokens > b.capacity {
		b.tokens = b.capacity
	}
	if b.tokens >= 1 {
		b.tokens -= 1
		return true
	}
	return false
}

func (l *Limiter) getBucket(key string) *bucket {
	if v, ok := l.store.Load(key); ok {
		return v.(*bucket)
	}
	b := &bucket{
		tokens:   l.burst,
		last:     time.Now(),
		rps:      l.rps,
		capacity: l.burst,
	}
	actual, _ := l.store.LoadOrStore(key, b)
	return actual.(*bucket)
}
