.PHONY: all clean

all: picojson

picojson:
	curl -fsSL -O https://github.com/kazuho/picojson/archive/refs/tags/v1.3.0.tar.gz && \
  tar xvf v1.3.0.tar.gz && \
  rm v1.3.0.tar.gz && \
  mv picojson-1.3.0 picojson

clean:
	rm -rf picojson
