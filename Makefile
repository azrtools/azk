SOURCES=azk.sh
PREFIX=$(HOME)/bin

all:

install: .checkprefix $(PREFIX) $(addprefix .copy/, $(SOURCES))

.copy/%: %
	rm -f "$(PREFIX)/$(basename $<)"
	cp $(realpath $<) $(PREFIX)/$(basename $<)
	dos2unix $(PREFIX)/$(basename $<)
	chmod +x $(PREFIX)/$(basename $<)

.checkprefix:
	@echo '$(PATH)' | grep -qE '(^|:)$(PREFIX)($|:)' || echo "$(PREFIX) is not in your PATH!" >&2

$(PREFIX):
	test -d $@ || mkdir -p $@
