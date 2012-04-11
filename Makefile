.PHONY: dialyzer_warnings xref_warnings

REBAR=./rebar

all:
	./bootstrap

clean:
	@rm -rf bin/rebar ebin/*.beam inttest/rt.work

debug:
	@./bootstrap debug

check: debug xref dialyzer

xref: xref_warnings
	@diff -U0 xref_reference xref_warnings

xref_warnings:
	-@${REBAR} xref > xref_warnings

dialyzer: dialyzer_warnings
	@diff -U0 dialyzer_reference dialyzer_warnings

dialyzer_warnings:
	-@dialyzer -q -n ebin -Wunmatched_returns -Werror_handling \
		-Wrace_conditions > dialyzer_warnings
docs:
	echo No docs are built in rebar

# Gets the dependencies to the deps folder. It does not try to compile them
# For deployar to make the tarball of the source code so no compiling is
# required
getdeps:
	${REBAR} get-deps

# Gets the dependencies to the deps folder. It does try to compile them
deps:
	${REBAR} get-deps && ${REBAR} compile

# Buckets are now compiled when compile target is issued. This way we can
# keep the same targets for deployar!
compile:
	${REBAR} compile
	${REBAR} xref | grep -v "is unused export (Xref)"

release: all
	echo Just releasing a dummy package!


