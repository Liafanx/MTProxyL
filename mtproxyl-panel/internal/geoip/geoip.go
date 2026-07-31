package geoip

import (
	"net"

	"github.com/oschwald/maxminddb-golang"
)

type IPInfo struct {
	IP          string `json:"ip"`
	Country     string `json:"country"`
	CountryName string `json:"country_name"`
	City        string `json:"city"`
	ASN         uint   `json:"asn,omitempty"`
	ASNOrg      string `json:"asn_org,omitempty"`
}

type Lookup struct {
	db    *maxminddb.Reader
	asnDB *maxminddb.Reader
}

func New(dbPath, asnDBPath string) (*Lookup, error) {
	db, err := maxminddb.Open(dbPath)
	if err != nil {
		return nil, err
	}
	l := &Lookup{db: db}
	if asnDBPath != "" {
		asnDB, err := maxminddb.Open(asnDBPath)
		if err != nil {
			db.Close()
			return nil, err
		}
		l.asnDB = asnDB
	}
	return l, nil
}

func (l *Lookup) Close() error {
	err := l.db.Close()
	if l.asnDB != nil {
		if e := l.asnDB.Close(); e != nil && err == nil {
			err = e
		}
	}
	return err
}

type mmdbRecord struct {
	Country struct {
		ISOCode string            `maxminddb:"iso_code"`
		Names   map[string]string `maxminddb:"names"`
	} `maxminddb:"country"`
	City struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"city"`
}

type asnRecord struct {
	ASN uint   `maxminddb:"autonomous_system_number"`
	Org string `maxminddb:"autonomous_system_organization"`
}

func (l *Lookup) LookupIPs(ips []string) []IPInfo {
	results := make([]IPInfo, 0, len(ips))
	for _, ipStr := range ips {
		info := IPInfo{IP: ipStr, Country: "??", CountryName: "Unknown"}

		ip := net.ParseIP(ipStr)
		if ip == nil {
			results = append(results, info)
			continue
		}

		var record mmdbRecord
		err := l.db.Lookup(ip, &record)
		if err != nil || record.Country.ISOCode == "" {
			results = append(results, info)
			continue
		}

		info.Country = record.Country.ISOCode
		if name, ok := record.Country.Names["en"]; ok {
			info.CountryName = name
		}
		if name, ok := record.City.Names["en"]; ok {
			info.City = name
		}

		if l.asnDB != nil {
			var asn asnRecord
			if err := l.asnDB.Lookup(ip, &asn); err == nil && asn.ASN != 0 {
				info.ASN = asn.ASN
				info.ASNOrg = asn.Org
			}
		}

		results = append(results, info)
	}
	return results
}
