# Tom's Receptenboek

Een gedeelde receptenapp voor het huishouden: recepten toevoegen (ook via een link of geplakte tekst uit Notes), zoeken, filteren, een persoonlijk weekmenu en een boodschappenlijst.

- **App:** `index.html`, een enkele pagina die via GitHub Pages draait.
- **Gegevens:** Supabase (database, inloggen, foto's). Alleen leden die zijn uitgenodigd kunnen erbij.
- **Link inlezen:** de Supabase Edge Function in `supabase/functions/recept-ophalen`.

De publishable key in `index.html` is bedoeld om openbaar te zijn. De toegang tot gegevens wordt geregeld met Row Level Security in de database.
