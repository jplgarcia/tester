# Third-party sources, fetched by commit and checked by sha256.
PICOJSON_COMMIT := 25fc213cca61ea22b3c2e4db8def9927562ba5f7
PICOJSON_SHA256 := 5ddf7276d04926da7be243e7af49258e78cc27278ee9097ba45b942c7a6b5f9d

SHA256SUM := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")

.PHONY: all clean

all: picojson/picojson.h

# picojson v1.3.0 (tag commit 25fc213c), single header
picojson/picojson.h:
	mkdir -p picojson
	curl -fsSL -o $@.part https://raw.githubusercontent.com/kazuho/picojson/$(PICOJSON_COMMIT)/picojson.h
	echo "$(PICOJSON_SHA256)  $@.part" | $(SHA256SUM) -c -
	mv $@.part $@

clean:
	rm -rf picojson
