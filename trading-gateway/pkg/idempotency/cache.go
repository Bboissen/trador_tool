package idempotency

import (
	"sync"
	"time"
)

// Cache provides a time-bounded idempotency store.
type Cache struct {
	mu    sync.Mutex
	items map[string]entry
	ttl   time.Duration
}

type entry struct {
	value     any
	expiresAt time.Time
}

// New returns a cache with the provided ttl.
func New(ttl time.Duration) *Cache {
	return &Cache{
		items: make(map[string]entry),
		ttl:   ttl,
	}
}

// Get returns the stored value if present and not expired.
func (c *Cache) Get(key string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c == nil {
		return nil, false
	}
	if item, ok := c.items[key]; ok {
		if time.Now().Before(item.expiresAt) {
			return item.value, true
		}
		delete(c.items, key)
	}
	return nil, false
}

// Set stores a value until ttl expiry.
func (c *Cache) Set(key string, value any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c == nil {
		return
	}
	c.items[key] = entry{
		value:     value,
		expiresAt: time.Now().Add(c.ttl),
	}
}
