# Makefile for the LapEE paper.
#
# Requirements:
#   - TeX Live 2020 or newer (tlmgr install: latex, latex-bin, tikz,
#     biblatex, biber, amsmath, geometry, hyperref, booktabs, microtype,
#     enumitem, xcolor).
#   - biber (shipped with modern TeX Live).
#
# Targets:
#   make            Build main.pdf via pdflatex + biber + pdflatex + pdflatex.
#   make quick      Build once with pdflatex (for fast iteration; bibliography
#                   will be stale if refs changed).
#   make clean      Remove intermediate build artifacts.
#   make distclean  Also remove the output PDF.
#   make watch      Rebuild on save (requires latexmk).

PAPER   := main
TEX     := pdflatex
TEXOPTS := -interaction=nonstopmode -halt-on-error -file-line-error
BIBER   := biber
LATEXMK := latexmk

.PHONY: all quick clean distclean watch

all: $(PAPER).pdf

$(PAPER).pdf: $(PAPER).tex references.bib
	$(TEX) $(TEXOPTS) $(PAPER).tex
	$(BIBER) $(PAPER) || true
	$(TEX) $(TEXOPTS) $(PAPER).tex
	$(TEX) $(TEXOPTS) $(PAPER).tex

quick:
	$(TEX) $(TEXOPTS) $(PAPER).tex

watch:
	$(LATEXMK) -pdf -pvc -interaction=nonstopmode -halt-on-error $(PAPER).tex

clean:
	rm -f $(PAPER).aux $(PAPER).log $(PAPER).out $(PAPER).toc \
	      $(PAPER).bbl $(PAPER).blg $(PAPER).bcf $(PAPER).run.xml \
	      $(PAPER).fls $(PAPER).fdb_latexmk $(PAPER).synctex.gz \
	      $(PAPER).nav $(PAPER).snm $(PAPER).vrb

distclean: clean
	rm -f $(PAPER).pdf
