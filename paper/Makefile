# Makefile for the LapEE paper.
#
# Requirements:
#   - TeX Live 2020 or newer (tlmgr install: latex, latex-bin, tikz,
#     biblatex, biber, amsmath, geometry, hyperref, booktabs, microtype,
#     enumitem, xcolor, listings).
#   - biber (shipped with modern TeX Live).
#
# Targets:
#   make            Build main.pdf.
#   make main       Build main.pdf only.
#   make quick      Single-pass build of main.pdf (no biber).
#   make clean      Remove intermediate build artifacts.
#   make distclean  Also remove output PDFs.
#   make watch      Rebuild main.pdf on save (requires latexmk).

TEX     := pdflatex
TEXOPTS := -interaction=nonstopmode -halt-on-error -file-line-error
BIBER   := biber
LATEXMK := latexmk

# main.tex uses biber for the bibliography.
ALL_PDFS := main.pdf

.PHONY: all main quick clean distclean watch

all: $(ALL_PDFS)

main: main.pdf

main.pdf: main.tex references.bib
	$(TEX) $(TEXOPTS) main.tex
	$(BIBER) main || true
	$(TEX) $(TEXOPTS) main.tex
	$(TEX) $(TEXOPTS) main.tex

quick:
	$(TEX) $(TEXOPTS) main.tex

watch:
	$(LATEXMK) -pdf -pvc -interaction=nonstopmode -halt-on-error main.tex

clean:
	rm -f *.aux *.log *.out *.toc *.bbl *.blg *.bcf *.run.xml \
	      *.fls *.fdb_latexmk *.synctex.gz *.nav *.snm *.vrb

distclean: clean
	rm -f $(ALL_PDFS)
