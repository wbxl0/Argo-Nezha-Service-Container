package geoip

import (
	_ "embed"
	"errors"
	"net"
	"os"
	"strings"
	"sync"

	maxminddb "github.com/oschwald/maxminddb-golang"
)

//go:embed geoip.db
var db []byte

// ipinfoRecord matches the flat schema of ipinfo's country.mmdb
// (country / country_name / continent / continent_name are plain strings).
type ipinfoRecord struct {
	Country   string `maxminddb:"country"`
	Continent string `maxminddb:"continent"`
}

type mmdbCode struct {
	ISOCode string `maxminddb:"iso_code"`
}

// maxmindRecord matches MaxMind's nested schema (GeoLite2-Country).
type maxmindRecord struct {
	Country   mmdbCode `maxminddb:"country"`
	Continent mmdbCode `maxminddb:"continent"`
}

type overrideEntry struct {
	network *net.IPNet
	country string
}

var (
	dbOnce = sync.OnceValues(func() (*maxminddb.Reader, error) {
		db, err := maxminddb.FromBytes(db)
		if err != nil {
			return nil, err
		}
		return db, nil
	})

	overrideOnce = sync.OnceValue(func() []overrideEntry {
		return parseOverrides(os.Getenv("GEOIP_OVERRIDES"))
	})
)

// parseOverrides accepts "CIDR=CC,CIDR=CC" (e.g. "13.140.248.0/24=JP").
// Malformed items are ignored on purpose: a bad entry must never take the
// panel down, it only leaves the database answer in place.
func parseOverrides(raw string) []overrideEntry {
	var entries []overrideEntry
	for _, item := range strings.Split(raw, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		cidr, country, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		cidr = strings.TrimSpace(cidr)
		country = strings.ToLower(strings.TrimSpace(country))
		if country == "" {
			continue
		}
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			continue
		}
		entries = append(entries, overrideEntry{network: network, country: country})
	}
	return entries
}

// Lookup returns the lowercase ISO country code for ip.
//
// Precedence: GEOIP_OVERRIDES (operator-managed CIDR table, wins over the
// database) -> ipinfo flat schema -> MaxMind nested schema -> continent.
func Lookup(ip net.IP) (string, error) {
	if ip == nil {
		return "", errors.New("nil IP")
	}

	for _, entry := range overrideOnce() {
		if entry.network.Contains(ip) {
			return entry.country, nil
		}
	}

	reader, err := dbOnce()
	if err != nil {
		return "", err
	}

	var flat ipinfoRecord
	if err := reader.Lookup(ip, &flat); err == nil && flat.Country != "" {
		return strings.ToLower(flat.Country), nil
	}

	var nested maxmindRecord
	if err := reader.Lookup(ip, &nested); err == nil && nested.Country.ISOCode != "" {
		return strings.ToLower(nested.Country.ISOCode), nil
	}

	if flat.Continent != "" {
		return strings.ToLower(flat.Continent), nil
	}
	if nested.Continent.ISOCode != "" {
		return strings.ToLower(nested.Continent.ISOCode), nil
	}

	return "", errors.New("IP not found")
}
