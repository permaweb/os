# Makefile for the LapEE paper + companion design notes.
#
# Requirements:
#   - TeX Live 2020 or newer (tlmgr install: latex, latex-bin, tikz,
#     biblatex, biber, amsmath, geometry, hyperref, booktabs, microtype,
#     enumitem, xcolor, listings).
#   - biber (shipped with modern TeX Live).
#
# Targets:
#   make            Build all PDFs (main + companion design notes).
#   make main       Build main.pdf only.
#   make notes      Build all *-note.tex / beam-tagged-mac.tex companions.
#   make quick      Single-pass build of main.pdf (no biber).
#   make clean      Remove intermediate build artifacts.
#   make distclean  Also remove output PDFs.
#   make watch      Rebuild main.pdf on save (requires latexmk).

TEX     := pdflatex
TEXOPTS := -interaction=nonstopmode -halt-on-error -file-line-error
BIBER   := biber
LATEXMK := latexmk

# main.tex uses biber for the bibliography; companion notes typically
# don't carry references and build with a single pdflatex pass.
NOTES   := beam-tagged-mac.pdf
ALL_PDFS := main.pdf $(NOTES)

.PHONY: all main notes quick clean distclean watch

all: $(ALL_PDFS)

main: main.pdf

notes: $(NOTES)

main.pdf: main.tex references.bib
	$(TEX) $(TEXOPTS) main.tex
	$(BIBER) main || true
	$(TEX) $(TEXOPTS) main.tex
	$(TEX) $(TEXOPTS) main.tex

# Companion design notes — single pdflatex pass, no biber.
%.pdf: %.tex
	$(TEX) $(TEXOPTS) $<
	$(TEX) $(TEXOPTS) $<

quick:
	$(TEX) $(TEXOPTS) main.tex

watch:
	$(LATEXMK) -pdf -pvc -interaction=nonstopmode -halt-on-error main.tex

clean:
	rm -f *.aux *.log *.out *.toc *.bbl *.blg *.bcf *.run.xml \
	      *.fls *.fdb_latexmk *.synctex.gz *.nav *.snm *.vrb

distclean: clean
	rm -f $(ALL_PDFS)
