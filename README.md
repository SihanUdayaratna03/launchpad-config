# Mini Hackathon Chat Widget — Frontend-Only (No Backend)

A chatbot that answers Rules & Regulations questions entirely in the browser.
No server, no API key, no vector database, no LLM calls, no monthly bill.

## Files

| File | Purpose |
|---|---|
| `rules-data.json` | The knowledge base — 21 Q&A entries extracted from the Rules & Regulations doc |
| `chatbot-widget.js` | Loads the JSON, matches questions, renders the chat UI |
| `chatbot-widget.css` | Styling for the floating widget |
| `demo.html` | Example page showing the widget embedded |

## How it works

1. The script tag's `data-rules` attribute tells it where the JSON file lives.
2. On page load, it `fetch()`es that JSON once and keeps it in memory.
3. When someone types a question, it strips stopwords, tokenizes both the
   question and every FAQ entry's `question` + `keywords`, and scores each
   entry by token overlap (exact match = 3 points, partial/substring match =
   1 point — this gives typo tolerance without needing a real spellchecker).
4. The highest-scoring entry above a confidence threshold (3) is shown as
   the answer. Below that, it shows a fallback message with suggested topics.

No network request happens after the initial JSON fetch — every subsequent
question is answered instantly, client-side.

## Step-by-step: adding it to your site

### 1. Copy the files
Drop `chatbot-widget.js`, `chatbot-widget.css`, and `rules-data.json` into
your website's root folder (or an `/assets` folder — just keep the relative
path in mind for step 2).

### 2. Add two lines before `</body>` on every page you want the chatbot on
```html
<link rel="stylesheet" href="chatbot-widget.css">
<script src="chatbot-widget.js" data-rules="rules-data.json"></script>
```
If your files live in a subfolder, adjust the paths, e.g.
`data-rules="/assets/rules-data.json"`.

### 3. Test locally
Browsers block `fetch()` on `file://` pages, so serve the folder over HTTP
while developing:
```bash
python3 -m http.server 8000
```
Then open `http://localhost:8000/demo.html` (or your real page) and click
the chat bubble, bottom-right.

### 4. Update the knowledge base whenever rules change
Open `rules-data.json` and edit/add entries — no code changes needed. Each
entry looks like:
```json
{
  "id": "unique_id",
  "question": "A natural way someone might ask this",
  "keywords": ["a few", "extra trigger words", "synonyms"],
  "answer": "The answer text shown in the chat."
}
```
More `keywords` = better matching. Include the words people would actually
type, not just formal document language.

### 5. Deploy — free static hosting options

**Option A — GitHub Pages (recommended if the registration site is already
on GitHub)**
1. Push these files to a GitHub repo.
2. Repo → Settings → Pages → Source: select your branch (e.g. `main`) and
   root folder.
3. Your site is live at `https://<username>.github.io/<repo>/` within a
   couple of minutes.

**Option B — Netlify**
1. Go to [app.netlify.com/drop](https://app.netlify.com/drop).
2. Drag the whole project folder onto the page.
3. Netlify gives you a live URL immediately — no account required to try it,
   free account to keep it permanently.

**Option C — Vercel**
1. `npm i -g vercel` (one-time), then run `vercel` inside the project folder.
2. Follow the prompts — free tier, live URL in under a minute.

**Option D — It's already part of an existing site**
If the registration page is already hosted somewhere (WordPress, custom
server, etc.), you don't need a separate deploy at all — just upload the
three widget files alongside your existing site files and add the two
`<link>`/`<script>` lines from step 2.

### 6. (Optional) Tune the matching sensitivity
In `chatbot-widget.js`, the line
```js
var THRESHOLD = 3;
```
controls how confident the widget must be before answering. Lower it (e.g.
`2`) to answer more often but risk occasional wrong matches; raise it (e.g.
`4`) to be stricter and fall back to "I'm not sure" more often.

## Known limitations (same as any keyword-based system)

- No real language understanding — heavily rephrased or very vague questions
  may miss (this is exactly why Approaches 1 and 2 in the main proposal use
  an LLM instead).
- Every new type of question needs its own entry in `rules-data.json`.
- Can't combine info across multiple sections into one answer the way an
  LLM can — each answer is a single stored entry.

These are acceptable trade-offs for a $0, zero-maintenance FAQ widget, and
the JSON file itself can be reused as-is if you upgrade to Approach 2 later.
