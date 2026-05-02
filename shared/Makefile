# Based on https://hiltmon.com/blog/2013/07/03/a-simple-c-plus-plus-project-structure/
CC := gcc
SRCDIR := src
BUILDDIR := build
TARGETDIR := bin


SRCEXT := c
# List of source files for your thread library
SOURCES = $(shell find $(SRCDIR) -type f -name *.c)
# Generate the names of the thread library's object files
OBJECTS := $(patsubst $(SRCDIR)/%,$(BUILDDIR)/%,$(SOURCES:.$(SRCEXT)=.o))
CFLAGS := -O3 -g
INC := -I ../shared -I include

.PHONY: all rebuild shared clean

all: shared

rebuild: clean shared

# Generic rules for compiling a source file to an object file
${BUILDDIR}/%.o: ${SRCDIR}/%.${SRCEXT}
	@mkdir -p ${BUILDDIR}
	${CC} ${CFLAGS} ${INC} -c -o $@ $<

# Compile the pager and tag this compilation
shared: ${OBJECTS}
	@echo "Built shared objects: ${OBJECTS}"

clean:
	@echo "Cleaning..."
	@rm -rf ${BUILDDIR}
