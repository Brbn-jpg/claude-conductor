# FAQ

## Jak działa izolacja workerów w gridzie?
Każdy worker AI operuje w wydzielonym katalogu roboczym (worktree), co zapobiega konfliktom plików między równoległymi zadaniami. Dzięki temu zmiany wprowadzane przez jednego agenta nie wpływają na środowisko pracy innych, dopóki nie zostaną zatwierdzone. Zapewnia to wysoką stabilność i przewidywalność całego systemu.

## W jaki sposób przydzielane są zadania?
System kolejkowania monitoruje dostępne zasoby i rozdziela zadania do wolnych instancji workerów na podstawie ich obciążenia. Każdy proces posiada unikalny identyfikator, który pozwala na śledzenie postępów i logowanie zdarzeń w czasie rzeczywistym. Pozwala to na efektywne wykorzystanie mocy obliczeniowej bez ryzyka przeciążenia pojedynczego węzła.

## Czy można uruchomić wielu workerów na jednej maszynie?
Tak, architektura oparta na izolowanych procesach pozwala na uruchomienie wielu instancji na tym samym systemie operacyjnym. Kluczem do sukcesu jest odpowiednie zarządzanie portami oraz przestrzenią dyskową dla każdego workera z osobna. Takie podejście znacząco ułatwia skalowanie horyzontalne bez konieczności inwestowania w dodatkowy sprzęt.
