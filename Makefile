CXX := g++
CXXFLAGS := -std=c++17 -O2

# libcmt (headers + static library) ships in the machine-guest-tools .deb.
# The Dockerfile unpacks the pinned .deb and passes its prefix here.
LIBCMT_PREFIX ?= /usr

.PHONY: clean 3rdparty

dapp: dapp.cpp 3rdparty
	$(CXX) $(CXXFLAGS) -I$(LIBCMT_PREFIX)/include -o $@ dapp.cpp $(LIBCMT_PREFIX)/lib/libcmt.a

3rdparty:
	$(MAKE) -C 3rdparty

clean:
	@rm -rf dapp
	$(MAKE) -C 3rdparty clean

# Reproducible machine snapshot (Docker): .build/snapshot, .build/snapshot.tar.gz,
# .build/template-hash.txt, .build/build-info.txt. See scripts/build-snapshot.sh.
.PHONY: snapshot snapshot-clean
snapshot:
	scripts/build-snapshot.sh

# Cold build: no BuildKit cache, previous outputs removed (images are kept).
snapshot-clean:
	rm -rf .build/snapshot .build/root.tar .build/root.ext2 .build/snapshot.tar.gz*
	NO_CACHE=1 scripts/build-snapshot.sh
