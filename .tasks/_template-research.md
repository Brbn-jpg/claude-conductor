# Research: <temat>

> Szablon do **research-tasków** — wynikiem ma być zwięzły raport, nie zmiany w kodzie.
> Zapisz plik jako `.tasks/todo/research-<NNN>-<slug>.md`.
> Worker uruchomi gemini, który **eksploruje codebase**, pisze findings do
> `.tasks/research/<slug>.md` (utwórz katalog jeśli brak) i KONIEC — żadnych
> innych zmian w repo. Manager (Ty / Claude) czyta krótki raport zamiast
> czytać samodzielnie surowy kod.

## Cel
<!-- Czego chcesz się dowiedzieć? Np. "jak działa moduł X", "gdzie są wszystkie
     miejsca używające funkcji Y", "porównaj 3 podejścia do Z w kodzie". -->

## Zakres eksploracji
<!-- Które ścieżki / pliki / wzorce ma worker przeszukać. Im konkretniej, tym lepiej. -->
- `src/...`
- pliki pasujące do wzorca: ...
- pomiń: ...

## Pytania, na które ma odpowiedzieć
<!-- Lista pytań. Każde dostaje odpowiedź w raporcie. -->
1. ...
2. ...
3. ...

## Format wyjścia (DoD)
- **Plik wynikowy:** `.tasks/research/<slug>.md` (utwórz `.tasks/research/` jeśli nie istnieje)
- **Limit:** maks 300 słów
- **Struktura raportu:**
  - `## TL;DR` — 3 linie, najważniejsze wnioski
  - `## Findings` — bulletpointy, każde z odnośnikiem do pliku (`path/to/file.ext:LINE`)
  - `## Recommendations` *(opcjonalne)* — propozycje działań / kolejnych tasków

## Ograniczenia
- **NIE modyfikuj** żadnych plików spoza `.tasks/research/`.
- **NIE generuj** plików testowych ani kodu — to jest tylko raport.
- Cytaty z kodu max 5 linii każdy; reszta opisem.
