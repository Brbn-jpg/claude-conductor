# Tytuł zadania

> Zapisz plik jako `.tasks/todo/task-<NNN>-<krotki-slug>.md`.
> Worker grid odczyta go automatycznie. Nazwa pliku staje się TASK_NAME w logach
> i commitach (`[AI-Grid] Zrobiono <TASK_NAME>`), więc trzymaj się kebab-case.

## Cel
<!-- 1–2 zdania: co dokładnie ma zostać osiągnięte po wykonaniu zadania. -->

## Kontekst
<!-- Dlaczego to robimy? Linki do issue / dokumentów / wcześniejszych decyzji. -->
<!-- Stan obecny vs. stan oczekiwany. -->

## Pliki do modyfikacji
<!-- Konkretne ścieżki (jeden plik na linię). Jeśli plik trzeba utworzyć, dopisz "(nowy)". -->
- `path/to/file.ext`
- `path/to/other.ext` (nowy)

## Ograniczenia (Definition of Done)
<!-- Twarde reguły: czego NIE wolno ruszać, jakich API/konwencji się trzymać, -->
<!-- jak wygląda warunek ukończenia (np. test który musi przejść). -->
- Nie modyfikuj plików spoza listy powyżej.
- Zachowaj istniejący styl kodu i konwencję nazewnictwa.
- Po zmianach `TEST_CMD` workera musi przejść bez błędów.
- Nie dodawaj zewnętrznych zależności bez wyraźnej zgody.
