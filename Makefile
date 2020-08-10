# This makefile is forked from https://github.com/google/llvm-propeller/blob/bb-clusters/plo/Makefile
SHELL := /bin/bash -o pipefail

# Customizable variables.
ENABLE_EH  ?= OFF
BUILD_TYPE ?= Release
ENABLE_ASSERTS ?= OFF
CREATE_LLVM_PROF ?="create_llvm_prof"
RELEASE_LLVM_BIN ="/usr/bin"

DDIR := $(shell pwd)
LLVM_PROJECT ?= $(shell cd $(DDIR)/.. && pwd)
CLANG_VERSION := $(shell sed -Ene 's!^\s+set\(LLVM_VERSION_MAJOR\s+([[:digit:]]+)\)$$!\1!p' ${LLVM_PROJECT}/llvm/CMakeLists.txt)

check_environment:
	@if [[ -z "${CLANG_VERSION}" ]]; then \
	  echo "Invalid clang version found." ; \
	  exit 1 ; \
	fi
	echo "clang version is: ${CLANG_VERSION}" > $@

ITERATIONS ?= 10

#################################
# Important targets:
#  stage1-compiler: the compiler contains all the patches and used to do benchmark.
#  pgo-vanilla-compiler: PGO optimized compiler.
#  benchmark-*: Run compiler on test commands for timing.
#  all-compilers: build all compilers
#  all-benchmarks: run all benchmarks
#
#  run-commands.sh / commands: script that runs a compiler over hundreds of compilation jobs.

LLVM_SOURCE := $(shell find $(LLVM_PROJECT)/llvm \
                            $(LLVM_PROJECT)/clang \
                            $(LLVM_PROJECT)/lld \
			    $(LLVM_PROJECT)/libcxxabi \
        '(' -ipath "*/.git"      -o      \
            -ipath "*/test"      -o      \
            -ipath "*/tests"     -o      \
            -ipath "*/unittests" -o      \
            -ipath "*/gtest"     -o      \
            -ipath "*/googletest" ')' -type d  -prune -o \
        -type f '(' -iname "*.cpp" -o -iname "*.cc" -o -iname "*.c" \
                   -o -iname "*.h" -o -iname "*.td" ')' -print)

ifeq ($(J_NUMBER),)
CORES := $(shell grep ^cpu\\scores /proc/cpuinfo | uniq |  awk '{print $$4}')
THREADS  := $(shell grep -Ee "^core id" /proc/cpuinfo | wc -l)
THREAD_PER_CORE := $(shell echo $$(($(THREADS) / $(CORES))))
# leave some cores on the machine for other jobs.
USED_CORES := $(shell \
	if [[ "$(CORES)" -lt "3" ]] ; then \
	  echo 1 ; \
	elif [[ "$(CORES)" -lt "9" ]] ; then \
	  echo $$(($(CORES) * 3 / 4)) ; \
	else echo $$(($(CORES) * 7 / 8)); \
	fi )
J_NUMBER := $(shell echo $$(( $(USED_CORES) * $(THREAD_PER_CORE))))
endif

comma              := ,
STAGE1_BIN         := $(DDIR)/stage1/install/bin
LLD_OPT            := -fuse-ld=lld
FLAVORS            := stage1 pgo-vanilla pgo-split plain afdo-vanilla afdo-split pgo-hcs
ALL_COMPILERS      := $(foreach F,$(FLAVORS),$(F)-compiler)
ALL_BENCHMARKS     := $(foreach F,$(FLAVORS),benchmark-$(F))

gen_compiler_flags  = -DCMAKE_C_FLAGS=$(1) -DCMAKE_CXX_FLAGS=$(1)
gen_linker_flags    = -DCMAKE_EXE_LINKER_FLAGS=$(1) -DCMAKE_SHARED_LINKER_FLAGS=$(1) -DCMAKE_MODULE_LINKER_FLAGS=$(1)

# $1 are compiler cluster.
# $2 are ld flags.
gen_build_flags     = $(call gen_compiler_flags,$(1)) $(call gen_linker_flags,$(2))

# Use "_opt" suffix to name a bare option, e.g., options that are to be wrapped by -DCMAKE_C_FLAGS="....".
gc_sections_opt            := -Wl,-gc-sections
keep_section_opt           := -Wl,-z,keep-text-section-prefix
split_linker_opt           := -Wl,-lto-split-machine-functions -Wl,-z,keep-text-section-prefix

# Use "_flags" suffix to name cmake options, e.g., options that are wrapped by "-DCMAKE_XXX".
split_flags := $(call gen_build_flags,"-mllvm -enable-split-machine-functions","${LLD_OPT} $(keep_section_opt)")

# $1 is any other cmake flags (optional)
# $2 is llvm enabled projects
# $3 is target
define build_compiler
	$(eval __toolchain=$(shell if [[ "$@" == "stage1/install/bin/clang" ]]; then echo "$(RELEASE_LLVM_BIN)" ; else echo "$(DDIR)/stage1/install/bin" ; fi))
	$(eval __comp_dir=$(DDIR)/$(shell echo $@ | sed -Ee 's!([^/]+)/.*!\1!'))
	if [[ -z "$(__comp_dir)" ]]; then echo "Invalid dir name" ; exit 1; fi
	echo "Building in directory: $(__comp_dir) ... " ;
	if [[ ! -e "$(__comp_dir)/build/CMakeCache.txt" ]]; then \
	    mkdir -p $(__comp_dir)/build ;                       \
	    cd $(__comp_dir)/build && cmake -G Ninja             \
		-DCMAKE_INSTALL_PREFIX=$(__comp_dir)/install     \
		-DLLVM_OPTIMIZED_TABLEGEN=On                     \
		-DCMAKE_BUILD_TYPE=$(BUILD_TYPE)                 \
		-DLLVM_ENABLE_EH=$(ENABLE_EH)                    \
		-DLLVM_ENABLE_RTTI=$(ENABLE_EH)                  \
		-DLLVM_ENABLE_LLD="On"                           \
		-DCMAKE_LINKER="lld"                             \
		-DLLVM_TARGETS_TO_BUILD="X86"                    \
		-DCMAKE_C_COMPILER="$(__toolchain)/clang"        \
		-DCMAKE_CXX_COMPILER="$(__toolchain)/clang++"    \
		-DCMAKE_ASM_COMPILER="$(__toolchain)/clang"      \
		$(1)                                             \
		-DLLVM_ENABLE_PROJECTS=$(2)                      \
		$(LLVM_PROJECT)/llvm;                            \
	fi
	ninja -j$(J_NUMBER) -C $(__comp_dir)/build $(3) 2>&1 | tee $(DDIR)/$(shell basename $(__comp_dir)).autolog || exit 1
	if ! echo "int main() {return 0;}" | $(__comp_dir)/build/bin/clang -x c -c - -o ./build_compiler.tmpout ; then \
		rm -f ./build_compiler.tmpout ; \
		echo Failed; \
		exit 1 ; \
	else \
		rm -f ./build_compiler.tmpout ; \
	fi
	touch $@
endef

all-compilers: $(ALL_COMPILERS)

all-benchmarks: $(ALL_BENCHMARKS)

stage1/install/bin/clang: check_environment $(LLVM_SOURCE)
	$(call build_compiler,-DLLVM_ENABLE_ASSERTIONS=$(ENABLE_ASSERTS) $(call gen_linker_flags,"-Wl$(comma)-build-id"),"clang;compiler-rt;lld",install)

stage1-compiler: %-compiler : %/install/bin/clang
	ln -sf $< $@
	touch $@

stage-pgo-vanilla/build/bin/clang-${CLANG_VERSION}: | stage1-compiler
	$(call build_compiler,-DLLVM_BUILD_INSTRUMENTED=IR,"clang;compiler-rt;lld",all)

stage-pgo-vanilla-compiler pgo-vanilla-compiler plain-compiler pgo-hcs-compiler afdo-vanilla-compiler afdo-split-compiler pgo-split-compiler: %-compiler: %/build/bin/clang-${CLANG_VERSION} | check_environment
	ln -sf $< $@
	touch $@

stage-pgo-vanilla.profdata: %.profdata: %-compiler run-commands.sh  | stage1-compiler
	./run-commands.sh $(shell readlink -f $<)
	$(STAGE1_BIN)/llvm-profdata merge -output=$@ `find $(dir $(shell readlink -f $<))../ -path "*/csprofiles/*.profraw" -o -path "*/profiles/*.profraw"`

pgo-vanilla/build/bin/clang-${CLANG_VERSION}: stage-pgo-vanilla.profdata
	$(call build_compiler,-DLLVM_PROFDATA_FILE=$(DDIR)/$< $(call gen_linker_flags,"$(gc_sections_opt) $(keep_section_opt)"),"clang;compiler-rt;lld",clang lld)

pgo-hcs/build/bin/clang-${CLANG_VERSION}: stage-pgo-vanilla.profdata
	$(call build_compiler,-DLLVM_PROFDATA_FILE=$(DDIR)/$< $(call gen_build_flags,"-mllvm --hot-cold-split -mllvm -enable-cold-section","$(gc_sections_opt) $(keep_section_opt)"),"clang;compiler-rt;lld",clang lld)

plain/build/bin/clang-${CLANG_VERSION}: | stage1-compiler
	$(call build_compiler, -DLLVM_ENABLE_LTO=Thin $(call gen_build_flags,"-g","-fuse-ld=lld $(gc_sections_opt) $(keep_section_opt) $(ro_segment_opt)"),"clang;compiler-rt;lld",clang lld)

afdo-vanilla/build/bin/clang-${CLANG_VERSION}: plain.afdo
	$(call build_compiler,-DLLVM_SAMPLEPROF_FILE=$(DDIR)/$< -DLLVM_ENABLE_LTO=Thin $(call gen_linker_flags,"$(gc_sections_opt) $(keep_section_opt)"),"clang;compiler-rt;lld",clang lld)

afdo-split/build/bin/clang-${CLANG_VERSION}: plain.afdo
	$(call build_compiler,-DLLVM_SAMPLEPROF_FILE=$(DDIR)/$< -DLLVM_ENABLE_LTO=Thin $(call split_flags),"clang;compiler-rt;lld",clang lld)

pgo-split/build/bin/clang-${CLANG_VERSION}: stage-pgo-vanilla.profdata stage1-compiler
	$(call build_compiler,-DLLVM_PROFDATA_FILE=$(DDIR)/$< $(call split_flags),"clang;compiler-rt;lld",clang lld)

plain.perfdata: plain-compiler run-commands.sh
	perf record -o $@ -e br_inst_retired.near_taken:u -j any,u -- ./run-commands.sh $(shell readlink -f $<)

# The internal version of create_llvm_prof must be used here since the open source version cannot produce a
# format which is compatible with llvm as of 07/24/20.
plain.afdo: plain-compiler plain.perfdata
	${CREATE_LLVM_PROF} --binary=`readlink -f $<` --profile=$(DDIR)/plain.perfdata --logtostderr --out=$(DDIR)/$@

benchmark-dir.o: | stage1-compiler
	mkdir -p benchmark-dir/source
	mkdir -p benchmark-dir/build
	rsync -av -f "- .git*" -f "+ clang/***" -f "+ lld/***" -f "+ llvm/***" -f "- *" $(LLVM_PROJECT)/ benchmark-dir/source/
	cd benchmark-dir/build ; \
		export TOOLCHAIN="$(DDIR)/stage1/install/bin" ; \
		cmake -G Ninja -DCMAKE_C_COMPILER=$${TOOLCHAIN}/clang -DCMAKE_CXX_COMPILER=$${TOOLCHAIN}/clang++ -DCMAKE_ASM_COMPILER=$${TOOLCHAIN}/clang \
			       -DLLVM_ENABLE_PROJECTS="clang;lld" $(DDIR)/benchmark-dir/source/llvm ; \
		ninja clang lld
	echo "int main() {return 0;}" | benchmark-dir/build/bin/clang -x c -c - -o $@
	if [[ -z "benchmark-dir.o" ]]; then rm $@ ; exit 1; fi

run-commands.sh: benchmark-dir.o | stage1-compiler
	rm -f commands
	ninja -C benchmark-dir/build -t commands clang \
            | grep -E "^$(DDIR)/stage1/install/bin/clang\+?\+? " \
            | grep -Fe " -c " \
            | sed -Ee 's!^$(DDIR)/stage1/install/bin/clang\+\+ !$${CCP} -x c++ !' \
                   -e 's!^$(DDIR)/stage1/install/bin/clang !$${CCP} !' \
                   -e 's!^!cd $(DDIR)/benchmark-dir/build \&\& !' >> commands
	if [[ -z `cat commands` ]]; then \
		echo "Empty commands file, ERROR." ; exit 1 ; \
	fi
	echo "export CCP=\$$(cd \$$(dirname \$$1); pwd)/\$$(basename \$$1)" > $@
	echo "head -n 500 commands | xargs -P50 -L1 -d \"\\n\" bash -c" \
                >> $@
	chmod +x $@

$(ALL_BENCHMARKS): benchmark-%: %-compiler run-commands.sh
	@{ for i in {1..${ITERATIONS}}; do \
		echo "Running $@ ... iteration $$i/${ITERATIONS} ..." ; \
		/usr/bin/time --format "USER:%U SYS:%S WALL:%e STATUS:%x" ./run-commands.sh $(shell readlink -f $<) 2>&1 ; \
	   done ; \
	} | tee -a $@.result

.phony: clean clean-all clean-sample
.phone: $(foreach F,$(FLAVORS),dummy-$(F))
$(foreach F,$(FLAVORS),dummy-$(F)):

$(foreach F,$(FLAVORS),clean-$(F)): clean-%: dummy-%
	rm -fr $(subst dummy-,,$<){,-compiler,.profdata,.perfdata,.fdata,.yaml,.profile,.cfg,.size-summaries}
	if [[ "$(subst dummy-,,$<)" == "pgo" ]]; then rm -fr stage-pgo ; fi

clean:
	for F in $(filter-out stage1,$(FLAVORS)) stage-pgo-labels stage-pgo-vanilla stage-pgo-relocs stage-cspgo ; do \
	  rm -fr $${F}{,-compiler,.profdata,.perfdata,-compiler.propeller,.fdata,-compiler.yaml,.profile,.cfg,.size-summaries} ; \
	  rm -f benchmark{-,pmu-}$${F}.result ; \
	  rm -f benchmark-pmu-$${F}.{result,pmu} ; \
	done
	rm -f  check_environment
	rm -f  commands run-commands.sh

clean-all: clean
	rm -fr stage1 ; rm -fr stage1-compiler; rm -fr test-build
	rm -fr benchmark-dir.o benchmark-dir/
	rm *.autolog
