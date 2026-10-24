# 🔥 EmberGuide

A lightweight, family-friendly dashboard for [Canvas LMS](https://www.instructure.com/canvas) built with Ruby.

The dashboard provides a simple view of the school information that matters most day-to-day:

* ⚠️ Missing assignments
* ✅ Canvas to-do list with completion controls
* 📅 Assignments due in the next 7 days
* ✅ Submission status
* 📊 Editable assignment grades, calculated course estimates, and recent scores
* ✍️ Manual classes and assignments for coursework outside Canvas
* 🔑 Canvas API token expiration
* 💾 Cached data when Canvas is temporarily unavailable
* 🏠 Home Assistant status and change-event API
* 📱 Mobile and iPad-friendly interface
* 🎓 Branded Home Assistant app-store artwork

The interface uses a responsive dark analytics theme with compact navigation,
high-contrast cards, and locally rendered grade trend charts.

It was designed to run continuously as a **Home Assistant add-on on a Raspberry Pi**, but it can also be run locally on macOS or another machine with Ruby.

---

## Why?

Canvas contains a lot of information, but checking several courses to answer a simple question like:

> "What homework do I still need to do?"

can require a surprising amount of navigation.

This dashboard uses the Canvas API to collect that information and present it on a single page designed to be left open, bookmarked, or added to an iPad Home Screen.

---

## Product tour

### See the whole school day at a glance

![EmberGuide dashboard with grade snapshot and prioritized assignments](docs/screenshots/dashboard-overview.png)

EmberGuide turns a busy Canvas account into one calm starting point. The
dashboard combines current course averages with a short, urgency-ordered list
of what needs attention next, so students can answer “What should I work on?”
without opening every class.

### Keep small responsibilities from slipping through

![Student to-do list with classes, dates, and completion controls](docs/screenshots/student-todos.png)

Canvas planner notes and personal reminders live together in a focused to-do
list. Students can add, edit, and complete items directly from the dashboard,
while course labels and due times keep each task grounded in the school day.

### Make the rest of the week predictable

**This Week in Class** shows each class's current Canvas module with links to
its assignments, quizzes, and discussions, plus turned-in and due-tomorrow
status. Anything beyond the top three in **What to Do Next** expands in place,
so the rest of the week's unfinished work is one click away.

### Show progress as a trend, not a verdict

![Grade trend charts for six classes on an A through F scale](docs/screenshots/grade-trends.png)

Encouraging Chart.js cards place every class on the same A–F scale and rebuild
the cumulative grade after each assignment. Students can see whether a class
is steady, improving, or needs attention without overreacting to a single
score.

### Explain the number behind the letter

![Detailed mathematics grade card with recent assignment scores](docs/screenshots/assignment-grades.png)

Course details connect the overall percentage to the assignments that produced
it. Recent scores, points possible, dates, and percentages make the estimate
easy to understand, while local grade editing supports corrections and work
tracked outside Canvas.

> **Demo data:** Every grade, assignment, date, and score shown above is
> illustrative data created for the EmberGuide demo. The displayed profile does
> not contain a real student's academic record.

---

## Features

EmberGuide is organized around the questions students and families ask every
day: What needs attention, what is coming next, and how is each class going?

### 🎯 A clear next step

**What to Do Next** turns missing and upcoming work into a short,
urgency-ordered action list. Missing assignments remain prominent, while direct
Canvas links make it easy to move from planning to doing.

### ✅ To-dos and a predictable week

Create, edit, and complete Canvas planner notes without leaving the dashboard.
The seven-day view groups coursework by date and shows each class, due time,
and submission status, including work from classes tracked outside Canvas.

### Class modules and this week's work

Open **Modules** to browse the weekly instructions, readings, links, and work
inside each Canvas class. Items retain the teacher's ordering and link back to
Canvas. Due dates and completion requirements appear where Canvas supplies them;
a completed requirement does not necessarily mean an assignment was submitted.
Text headers that act as announcements, such as "‼️ Unit 2 Test on Friday ‼️"
above a week of day pages, show as highlighted notes instead of folders, both on
the Modules page and on the This Week in Class cards.

The dashboard and Modules page show **This Week in Class**: each class's first
module, skipping any module whose name contains "Resources", since teachers list
the current week first. It links straight to that module's assignments, quizzes,
and discussions. Assignments and graded quizzes show their turned-in status,
and graded work shows its score (for example, "Graded · 8/10"), including any
local grade corrections.
Classes that post the week only as daily pages show those pages instead.

Unfinished module work due tomorrow is also added to **What to Do Next** when
that assignment is not already listed there.

Click a page, assignment, quiz, or discussion to read its instructions right in
EmberGuide. The text for This Week in Class is saved during the regular Canvas
refresh and re-checked at most once an hour. Other items on the Modules page are
fetched from Canvas the first time they are opened and then kept with the cache.
Only the text and links are saved: images, attached files, and embedded content
appear as placeholders or links, so use **Open in Canvas** for those. Locked
items, links, files, and external tools still open in Canvas.

Canvas pages linked directly from this week's daily pages are also saved and
re-checked hourly. Expand them under **Links** to read the full linked page
inside EmberGuide, or use **Open in Canvas**. Only pages on the same Canvas
server and in the same class are fetched; their own links are not followed.
Repeated links share a cached copy. If a linked page cannot be refreshed, an
error appears alongside its last saved copy when available.

Assignments open the same way everywhere they appear: **What to Do Next** cards,
**Missing**, **Recent Canvas Grades**, and module assignments and quizzes. Click
one to read the teacher's description; a card with instructions expands across
the row and shows **Details**/**Hide details**. Each Canvas refresh saves every
assignment in the visible classes (one paginated request per class), and a
description is only re-read when Canvas reports that the assignment changed.
Assignments without a description still link straight to Canvas. The grade
editor in Settings and the school calendar do not show descriptions.

Modules refresh with the existing Canvas refresh and are included in the cached
data. If a class's module refresh fails, the view reports the failure and shows
its saved copy when available.

### 💬 Spark, the homework helper (optional, local AI)

Connect a [llama.cpp](https://github.com/ggml-org/llama.cpp) server on your home
network, such as a gaming PC, and **Spark** appears in the menu for questions like
"What should I focus on tonight?" or "What should I study for the Unit 2 test?". By
default, answers come only from data EmberGuide has already saved: current grades, missing and
upcoming work, each class's This Week in Class module with its announcements
and saved instructions, every open assignment (not yet graded, not locked) with
its full instructions, the full text of directly linked class pages (once per
page), and recent scores. Linked pages are also checked for test and quiz
mentions. Instructions are never shortened, and
an assignment already described under This Week in Class isn't repeated. Nothing
is fetched from Canvas at question time, and the Canvas token is never sent.
**What Spark can see** on the Spark page previews the current saved school context
and about how many tokens it uses. Prompts also include recent chat turns and,
when available, previously saved web research. Because the full instructions are included,
pick a model with a large context window; in Automatic mode Spark tries another
installed model if the class notes don't fit.

On phones, a **Suggested questions** dropdown replaces the suggestion buttons.
Choosing a question sends it to Spark, just like clicking a suggestion on desktop.
The conversation area stays hidden until the first question and hides again
when starting a new conversation.
Replies scroll inside the conversation instead of pushing the question box down.
Progress updates and errors follow the bottom too, so they are not clipped
while you type your next question.
Spark uses simple Markdown for readable replies; common LaTeX arrow shortcuts
are displayed as arrows, but full LaTeX math rendering is not supported.
Scroll up in the conversation to reread earlier messages without being pulled
back to the latest text as Spark answers.
When web search is off, Spark can suggest turning on **Search the web** if
public sources would fill a specific gap, such as vocabulary definitions missing
from the saved class notes or extra practice for a lesson. It explains what
search could help find but never enables it automatically. Missing school-specific
facts, such as due dates or grades, still need Canvas or the teacher.

#### Saved conversations

Spark saves conversations on the EmberGuide server, so questions and answers
survive page refreshes and app restarts and can be opened from another device.
Expand **Previous Conversations** to open, rename, or delete one conversation.
The list shows the three most recent conversations at a time; scroll within it
to reach older conversations without expanding the page.
Compact edit and trash icons keep conversation actions on one row on all screens.
After the first successful reply, the local AI summarizes the subject in a short
title instead of repeating the question. A manually renamed title is never
overwritten. If subject generation fails, the reply remains saved and a notice
offers manual renaming. There is no
bulk-delete control or automatic history expiration. **New conversation** starts
a separate thread without deleting the previous one. A conversation's URL keeps
that thread selected on refresh. Opening Spark from navigation or without a
conversation selection always starts on the new-conversation page.

School context is built from current saved Canvas data when answering, used in
memory, and not copied into conversation history. History stores questions,
answers, timestamps, and any generated web-search query, source titles, links,
and bounded source excerpts. Relevant research from up to three recent successful searches can
be reused without running another search. Source excerpts remain untrusted
reference material and cannot override current Canvas instructions.

Full answers remain available in Previous Conversations even though model requests still use
only the latest twelve chat messages, with the existing per-message size limit.
Failed or interrupted answers are marked explicitly; incomplete answers are not
replayed as successful assistant messages. Refresh conversations to check a reply
started on another device. Restarts mark unfinished replies as interrupted.

History is stored in `spark_history.json` under `/data` in the Home Assistant
add-on or `emberguide/tmp` locally; `SPARK_HISTORY_FILE` can override that path.
Configured credentials are redacted from saved content. Conversations and their
saved web research are included in downloaded and emailed backups. Canvas data
is backed up separately, not repeated for each conversation or answer.
Deleting a conversation does not remove copies from existing backups, and
restoring one of those backups can bring it back.
The existing backup limits still apply: 10 MB per file and 25 MB overall.
Oversized backups fail explicitly instead of producing an archive that cannot
be restored; history is never silently trimmed to make it fit.

EmberGuide has no login: anyone who can access the app can read, rename, or
delete its saved conversations. Backups therefore contain private student chat
and saved web research and should be stored and emailed only where appropriate.

For public study resources, turn on **Search the web** before asking a
question. Expand **How web search works** below the checkbox for service and
privacy details. Spark first reads the local class context and conversation to identify
the actual lesson or vocabulary list and the explanation you want. It generates
a focused public search request automatically, such as definitions for the
vocabulary words in the teacher's study guide. Only that generated request and
a fixed educational objective go to
[Exa's hosted MCP service](https://exa.ai/docs/get-started/exa-mcp).
The original question, full local answer, grades, class notes, and chat history
are not attached to Exa requests. Spark then combines the web sources with its
local context to answer the original question.
The local handoff prompt removes identifying details and turns personal grades,
missing work, or scheduling concerns into public study topics or planning advice.
Known student and mapped teacher names are automatically removed from the
generated query before a final name-only privacy check. Exact configured
credentials are also stripped as a safety backstop. Percentages, fractions,
dates, and phrases about grades or missing assignments no longer trigger broad
privacy blocks. These steps are not a guarantee of anonymity: the model is
generating text from private context, and unknown names or other identifying
details might remain. Leave web search off for sensitive questions. If Spark
cannot identify a study topic or produce a readable search request, it reports
an error without sending a search.
No Exa API key, extra service, or tool-calling model is needed. Keyless access
has free service limits and requires internet access.

The toggle starts off and resets when starting a new conversation. Each
web-enabled question runs one search, using at most four sources with bounded
excerpts. Spark shows **Finding study material locally...**, then
**Searching the web...**, then streams its answer with
numbered citations and clickable **Web sources**. The generated query is labeled
**Spark searched the web for:**, with provider-neutral wording throughout the app.
Source text is untrusted
reference material, not instructions; teacher notes remain authoritative for
due dates and assigned work. Search failures and free-limit errors are shown
explicitly instead of silently answering without the requested sources.
Search preparation requests JSON output from the local model. If its handoff is
malformed, too long, still contains a known name, or lacks a study topic, Spark
tries once more locally before making any external search. The progress label
explains what it is fixing. If preparation still fails, the message distinguishes
a Spark formatting problem from missing topic details or a name-removal issue
and gives an appropriate next step, rather than calling every failure a privacy
violation. Requests for a completed assignment are translated into searches for
writing guidance or relevant concepts; Spark still helps the student write their
own response rather than producing finished graded work.
Turning web search off prevents new searches; prior answers remain in the
current conversation. **What Spark can see** previews saved school context,
not the additional per-question search results. The generated query appears
with the web sources. Preparing the request adds a local-model pass, so
web-enabled answers take longer.

Tests, quizzes, and benchmarks come first. Teachers often announce tests in
module headers and daily notes ("‼️ Unit 2 Test on Friday ‼️") rather than as
Canvas assignments, so Spark collects those mentions into a **Tests and
quizzes coming up** list. The list states which date each weekday falls on
("Friday = tomorrow"), puts tests today or tomorrow at the top, and skips
past dates. Weekday notices are anchored to their own module's dated week,
including labels such as `October 19-23` and `10/19-10/23`, rather than rolled
forward to the next occurrence of that weekday. On Saturday October 24, a
Friday notice in the October 19-23 module means October 23, not October 30.
Explicit Canvas due dates take precedence. A module without a readable date
label leaves weekday dates unconfirmed; refresh and page-edit timestamps do
not establish an announcement date. The saved context retains past notices
with their module date anchors, and Spark is instructed not to treat them as
upcoming or repeat earlier chat guesses. Spark is told to lead with confirmed
upcoming tests when asked what to focus on or study.
Test mentions in daily notes inherit that day within the dated module.
Review resources alone do not establish an upcoming test. Conditional sections
such as "If you were absent" are excluded from the universal upcoming-tests
summary, while the full instructions and their conditions remain available to
Spark. The assistant must not assume the student was absent or needs a make-up
test. Relative phrases such as "next week" use the source module's week and
do not imply an exact test day.

While Spark works, the answer bubble shows a progress bar with a time estimate
while it reads the class notes ("Reading your class notes… 65% · about 3s
left"), then the answer streams in as it's written. A follow-up question reuses
what the model already read, so it skips most of that step.

On an RTX 4070 (12 GB), Qwen3 14B Q4_K_M is a good fit:

```text
llama-server -m Qwen3-14B-Q4_K_M.gguf --host 0.0.0.0 --port 8080 -c 12288 \
  -ngl 99 -fa -ctk q8_0 -ctv q8_0 --jinja --api-key <secret>
```

Use Qwen3 8B Q5_K_M if the GPU also needs room for games. Allow the port only on
private networks in the PC's firewall. Spark's online/offline badge rechecks every
30 seconds while the page is open, whenever the tab comes back into view, and
after every answer. If the PC is off, Spark shows as offline and the rest of
EmberGuide is unaffected.

**Settings → Spark** shows the configured server and whether an API key is set
(never the key itself), and lists the models installed on the server so you can
pick one. **Automatic** (the default) uses whichever model is already running on
the PC; a model that isn't running makes the next answer wait while it loads.
Automatic prefers the running model with the largest context window, and if a
model's context is too small for the class notes (llama-server's
`exceed_context_size_error`), it retries once with another installed model. A
model you picked yourself isn't swapped; Spark says how many tokens it needs so
you can pick another or load it with a larger `--ctx-size`.
The choice is saved in EmberGuide's data folder. **Test Connection** confirms
the server is reachable, the key is accepted, and the chosen model is still
installed. The server address and key are changed only in the add-on options or
`.env`, not in the web UI, because EmberGuide pages have no login and anyone on
the network could otherwise redirect class data to another server. Picking a
model is allowed on the page because it only chooses between models already on
that server.

### 📈 Encouraging grade context

A compact snapshot shows every current course average, while locally rendered
Chart.js trends rebuild the cumulative grade after each assignment on a shared
A–F scale. Open any class to connect the overall letter grade to recent scores,
points possible, and dates.

Local grade tools can correct stale Canvas values, add grades from another
system, or temporarily hide an inaccurate assignment until Canvas updates. All
changes stay inside EmberGuide and never modify the Canvas gradebook.
The assignment editor also lists ungraded and upcoming Canvas work, so an
in-class activity or reminder can be hidden without assigning it a score.

> **Grade estimates:** EmberGuide calculates percentages from assignments
> available through the API. Weighted groups, grading periods, dropped work,
> and other teacher gradebook rules can make the official Canvas grade differ.

### 🧩 One place for every class

Add manual classes and assignments for coursework outside Canvas. Long Canvas
course names can be shortened, and irrelevant enrollments can be hidden
locally, without changing the student's actual Canvas enrollment.

### 🏆 Playful achievements and collectible badges

Celebrate consistent effort with **On-Time Run**, **Clear Slate**, and
**Strong Score Streak**. Strong scores default to 80%, with a configurable
target in Achievement Settings. Milestones track graded assignments completed
and the school-year journey.

Collect **20 permanent badges** across these five categories:

| Category | Badge goals |
| --- | --- |
| On-Time Run | 5 / 10 / 25 / 50 consecutive on-time assignments |
| Clear Slate | 5 / 10 / 20 / 30 consecutive tracked school days without missing work |
| Strong Score Streak | 5 / 10 / 20 / 30 consecutive scores at or above your target |
| Work Completed | 25 / 50 / 100 / 200 graded assignments |
| School Year Journey | 25% / 50% / 75% / 100% completed |

Earn playful titles like **Deadline Ninja**, **Supernova**, **Halfway Hero**,
and **Legend of the Backpack**. Locked badges are gray with progress toward
their goals; earned badges light up in mint, blue, lavender, and gold by tier,
with colorful backgrounds, borders, and glowing emblems. Unlocked badges
stay collected even when a streak resets or settings change. Badges unlock from
the progress observed when opening Achievements (not reconstructed past streaks).
Collection dates and earned badges are included in data backups.

### School calendar and year-long progress

The monthly calendar includes past events supplied by the connected feed.
Browsing a month also shows that month's event list, including past dates;
the default calendar page keeps the upcoming-events list. Some feeds omit
older events, so an empty past month does not necessarily mean school had no events.

The Achievements page shows completed and remaining school days using the first
and last dates configured in **Settings → Calendar**. Counting starts with
weekdays and subtracts clearly labeled calendar closures, named holidays, and
seasonal breaks. Minimum days, early releases, and late starts still count.
Calendar display-filter keywords do not change the school-day calculation.

Open **School-Day Review** in Calendar Settings to review the dates and event titles
used. Add no-school dates or force dates to count as school days (including makeup
Saturdays) in Calendar Settings. Overrides take priority and are included in
data backups. Days before today count as completed; today remains in the count
of days left. Totals are estimates: calendar feeds can omit closures or contain
events for other schools. Calendar Settings flags unavailable, stale, or incomplete-range
calendar data rather than presenting it as an exact attendance record.

### ✉️ Family-friendly digests and backups

Preview, send on demand, or schedule a responsive morning digest containing the
current grade snapshot, missing work, near-term assignments, schedule changes,
and recently posted grades. Download or email a checksum-verified ZIP backup of
cached and locally managed data, including Spark conversations, web research,
and saved school context, without including configured Canvas or Gmail credentials.

### 🏠 Designed for an always-on family dashboard

EmberGuide refreshes Canvas every ten minutes, caches the last successful
response for outages, and includes responsive/PWA metadata for phones and iPad
Home Screens. It runs locally or as a Home Assistant app on an always-on device
such as a Raspberry Pi.

### 🔔 Home Assistant awareness

Successful refreshes produce structured activity for missing work,
submissions, grades, due-date changes, and teacher feedback. Home Assistant can
turn those events into household notifications and automations, while status
and event APIs support other local integrations.

---

# Home Assistant Installation

The dashboard can run continuously as a Home Assistant app installed directly from GitHub.

This is particularly useful when Home Assistant OS is running on an always-on Raspberry Pi.

## Add the Repository

1. In Home Assistant, open **Settings → Apps → Install app**.
2. Open the three-dot menu and select **Repositories**.
3. Add this repository URL:

```text
https://github.com/sbalentine/emberguide
```

4. Refresh the app store and select **EmberGuide**.
5. Install the app and enter the Canvas configuration below.

---

## Home Assistant Configuration

The included `config.yaml` defines the add-on and exposes the dashboard web server.

Example:

```yaml
name: "EmberGuide"
description: "A clear, family-friendly guide to Canvas coursework"
version: "1.10.1"
url: "https://github.com/sbalentine/emberguide"
slug: "emberguide"
init: false

arch:
  - aarch64

ports:
  4567/tcp: 4567

ports_description:
  4567/tcp: "EmberGuide"

map:
  - addon_config:rw

options:
  canvas_url: ""
  canvas_token: ""
  token_expires: ""
  gmail_sender: ""
  gmail_app_password: ""
  llm_url: ""
  llm_api_key: ""

schema:
  canvas_url: str
  canvas_token: password
  token_expires: str
  gmail_sender: str
  gmail_app_password: password
  llm_url: str?
  llm_api_key: password?
```

Configure the Canvas URL, token, and expiration date through the Home Assistant add-on configuration. The Gmail sender and app password are optional and only required for scheduled emails. `llm_url` (for example `http://192.168.1.50:8080`) and `llm_api_key` are optional and turn on **Spark**; pick the model on **Settings → Spark**.

The token is provided to the application through Home Assistant's `/data/options.json` and does **not** need to be stored in the Git repository.

---

## Building the Add-on

After placing or updating the files:

1. Open **Home Assistant**
2. Go to **Settings → Apps**
3. Open the local **EmberGuide** add-on
4. Rebuild/update the add-on
5. Start it
6. Check the add-on logs

A successful startup should look similar to:

```text
Starting EmberGuide...
Loading cached Canvas data...
EmberGuide listening on port 4567
Refreshing Canvas data...
Canvas cache saved.
Canvas refresh successful at ...
```

---

## Activity Events and API

When installed in Home Assistant, EmberGuide fires each detected Canvas change
on the event bus as `emberguide_activity`. Create an automation with an **Event**
trigger using that event type; payload fields are available under
`trigger.event.data`.

Detected activity types include:

* `assignment_missing`
* `assignment_no_longer_missing`
* `assignment_submitted`
* `grade_posted`
* `grade_changed`
* `due_date_changed`
* `teacher_feedback_added`

For other local integrations, `GET /api/status` returns dashboard counts and the
latest event, while `GET /api/events?after=42&limit=100` returns events after a
known event ID. EmberGuide retains the latest 500 changes locally.

---

# Running Locally

## Requirements

You'll need:

* Ruby
* WEBrick
* A Canvas API access token

Check Ruby:

```bash
ruby --version
```

Install WEBrick if necessary:

```bash
gem install webrick
```

---

## Canvas API Token

Generate an access token through your Canvas account.

The exact location depends on how your school configures Canvas, but Canvas normally exposes access tokens through the user's account settings when permitted by the institution.

**Never commit your Canvas token to Git.**

---

## Local Configuration

Create a `.env` file in the project root:

```bash
CANVAS_URL='https://your-school.instructure.com'
CANVAS_TOKEN='your-canvas-token'
TOKEN_EXPIRES='YYYY-MM-DD'
```

For example:

```bash
CANVAS_URL='https://your-school.instructure.com'
CANVAS_TOKEN='your-secret-token-here'
TOKEN_EXPIRES='2026-12-14'
```

`.env` is excluded by `.gitignore`.

---

## Start the Dashboard

Make the local startup script executable:

```bash
chmod +x run-local.sh
```

Then run:

```bash
./run-local.sh
```

Open:

```text
http://localhost:4567
```

### Running Tests

Install the development dependencies and run the test suite:

```bash
bundle install
bundle exec ruby test/run.rb
```

The suite does not contact Canvas. GitHub Actions runs it on the latest Ruby version pinned in `.ruby-version` and builds the ARM64 Home Assistant image for every push and pull request.

The first launch may briefly display a waiting message while the initial Canvas API request completes.

After a successful refresh, local cached data is stored at:

```text
emberguide/tmp/canvas_cache.json
```

The `tmp` directory is ignored by Git.

---

# Configuration

The application supports two configuration environments.

### Home Assistant

Home Assistant stores configuration in:

```text
/data/options.json
```

Expected options:

```json
{
  "canvas_url": "https://your-school.instructure.com",
  "canvas_token": "...",
  "token_expires": "YYYY-MM-DD",
  "gmail_sender": "sender@gmail.com",
  "gmail_app_password": "...",
  "llm_url": "http://192.168.1.50:8080",
  "llm_api_key": "..."
}
```

### Local Development

Local development uses environment variables:

```text
CANVAS_URL
CANVAS_TOKEN
TOKEN_EXPIRES
GMAIL_SENDER
GMAIL_APP_PASSWORD
LLM_URL          # optional, enables Spark
LLM_API_KEY      # optional, matches llama-server --api-key
```

`run-local.sh` loads these values from `.env`.

---

### Scheduled Email Delivery

Gmail delivery is optional. Set `gmail_sender` and `gmail_app_password`, restart
EmberGuide, then configure recipients and schedules under **Scheduled Emails**.
Use a Google app password rather than the account's normal password.

The daily digest can be previewed without sending, delivered on demand, or
scheduled for 6:00 AM local time. Backups can be downloaded directly, emailed
on demand, or scheduled for 3:00 AM. Backup archives never include
`/data/options.json`, Canvas tokens, or Gmail credentials.

Enable **Include Spark overview** under **Scheduled Emails** to add an optional
**Today at a glance** section above the grades in both HTML and plain-text digests.
It summarizes saved class context and digest details into up to four short points:
confirmed tests, today's work and deadlines, relevant schedule changes, and useful
priorities. It uses the configured local Spark model, never web search or chat
history, and follows the same module-date and conditional make-up safeguards as
Spark chat. Missing or stale information must not be treated as proof of an empty
school day.

A separate daily-automation worker prepares the overview at **5:00 AM local time**.
It caches the latest result in `daily_overview.json` next to the Canvas cache
(`DAILY_OVERVIEW_FILE` can override the location). This derived cache is not
included in backups; the opt-in preference is. The worker catches up after a
restore as well: restoring a backup invalidates the derived overview so it cannot
describe a different saved dataset. It also catches up after a
restart later than 5:00 AM and allows three attempts per day, at least 20 minutes
apart. Each local-model generation has a 20-second total limit. Preview and email
delivery only read the cache; they never wait for the model. All recipients use
the same prepared overview.

The overview shows when it was prepared and when its Canvas data was refreshed.
The detailed email sections still use current saved data, which may have changed
since preparation. Only a result for today's local date is eligible: yesterday's
summary is never reused as today's. If today's overview is missing, invalid, or
unavailable, a notice appears and the normal digest still sends. Use **Generate
Overview Now** to prepare or refresh today's cache without sending an email,
including before 5:00 AM or after automatic retries are exhausted. A failed
refresh preserves any valid overview already prepared for today. The setting is
off by default and does not change existing email schedules.

Use **Restore Backup** under **Settings → Data Backup** to validate and import a
downloaded ZIP.
EmberGuide verifies the archive manifest, checksums, file list, and JSON data
before replacing any local state.

---

# Canvas API

The dashboard communicates with the Canvas REST API using Bearer-token authentication.

Requests use:

```text
Authorization: Bearer <CANVAS_TOKEN>
```

The application currently retrieves information including:

* Active courses
* Graded submissions
* Missing submissions
* Upcoming events/assignments
* Submission information for upcoming assignments

The Canvas instance URL (for example `https://your-school.instructure.com`) is configured with the `canvas_url` add-on option in Home Assistant, or the `CANVAS_URL` environment variable for local development and tests. The application will not start if it is missing or blank.

---

# Security

The Canvas access token provides access to information available to the associated Canvas account. The Gmail app password permits the dashboard to send mail through the configured Google account.

Treat it like a password.

Do not:

* Commit it to Git
* Put it in `README.md`
* Include it in screenshots
* Store it directly in source code
* Publish `/data/options.json`
* Publish your local `.env`
* Include the Canvas token or Gmail app password in a backup archive

Spark sends saved class data (names, assignments, grades, and module
instructions) to the configured `llm_url`. Point it only at a server you control
on your own network, and set an `--api-key` on llama-server.

Optional Spark web search automatically generates a focused public request
locally from the study material and user's intent. Only that request and a fixed
educational objective go to Exa's hosted MCP endpoint. Raw Canvas data and chat
history are not attached. Local anonymization, automatic removal of known
student/teacher names and configured credentials, and a final name check reduce
disclosure risk but cannot guarantee anonymity; leave the toggle off for sensitive questions.
Search results return to the configured Spark model for the final answer.

The repository's `.gitignore` excludes common secret and runtime files, but always review changes before pushing:

```bash
git status
```

You can also search the repository before publishing:

```bash
grep -RniE 'access_token|canvas_token|Bearer ' . \
  --exclude-dir=.git \
  --exclude='.gitignore'
```

References to variable names such as `canvas_token` or `"Bearer #{TOKEN}"` are expected. An actual token value should never appear.

---

# Development Workflow

Run the dashboard locally:

```bash
./run-local.sh
```

Make changes and test at:

```text
http://localhost:4567
```

To inspect existing local data without automatic Canvas refreshes or scheduled
email delivery, run the app directly with background workers disabled:

```bash
./run-local.sh --no-background
```

Check Ruby syntax:

```bash
ruby -c emberguide/app.rb
ruby -c emberguide/lib/canvas.rb
ruby -c emberguide/lib/helpers.rb
ruby -c emberguide/lib/dashboard_data.rb
```

Then commit:

```bash
git add .
git commit -m "Describe the change"
git push
```

Once the changes are working locally, increase the version in `emberguide/config.yaml` and push the changes. Home Assistant will then offer the new version as an update.

## Demo mode

EmberGuide includes a committed anonymized dataset for screenshots, product
evaluation, and local development without a Canvas connection:

```sh
ruby emberguide/app.rb --demo
```

The bundled data uses synthetic classes, assignments, IDs, URLs, and academic
records. Dates shift relative to the current day each time the app starts. All
writable settings are isolated under `emberguide/tmp/demo`, and Canvas
refreshes and scheduled email delivery are disabled.

Rebuild the bundled dataset from an existing local cache after the dashboard
data shape changes:

```sh
ruby script/create_demo_data.rb
```

Review the generated files in `emberguide/demo` before committing them.

## Project Structure

```text
emberguide/
├── repository.yaml
├── run-local.sh
├── test/
└── emberguide/
  ├── app.rb
  ├── Dockerfile
  ├── config.yaml
  ├── run.sh
  ├── lib/
  ├── views/
  ├── public/
  └── tmp/                # Local only; ignored by Git
```

### `emberguide/app.rb`

Starts the WEBrick web server and defines the dashboard, stylesheet, icon, and PWA manifest routes.

### `emberguide/lib/canvas.rb`

Handles Canvas configuration, authentication, API requests, and token expiration.

### `emberguide/lib/dashboard_data.rb`

Retrieves Canvas data, builds the dashboard data model, caches successful responses, and manages the background refresh process.

### `emberguide/lib/helpers.rb`

Contains presentation and assignment helpers such as date formatting, score formatting, course names, and submission status.

### `emberguide/views/dashboard.erb`

The HTML/ERB dashboard interface.

### `emberguide/public/dashboard.css`

Dashboard styling and responsive layout.

---

## Future development: Canvas OAuth login

A future **Connect to Canvas** flow could replace manually entered personal
access tokens with Canvas OAuth 2.0. Users would sign in on their school's
Canvas site and authorize EmberGuide; the app would then refresh short-lived
API access tokens automatically.

This requires a Canvas API developer key (client ID and client secret) issued
by the institution's Canvas administrator. A global developer key involves
Instructure and still needs to be enabled by each institution. OAuth therefore
cannot be offered for arbitrary schools without their integration approval.

Implementation would need secure credential storage, authorization-state
validation, automatic token refresh, disconnect/reconnect controls, and a
callback URL compatible with Canvas's registered redirect-URI requirements,
including local Home Assistant installations.

Before expanding beyond personal use, revisit authentication: Canvas's
documentation states that applications used by multiple users must use OAuth
and that asking other users to manually generate and enter personal access
tokens violates its API policy.

References: [Canvas OAuth overview](https://developerdocs.instructure.com/services/canvas/oauth2/file.oauth.md),
[developer keys](https://developerdocs.instructure.com/services/canvas/oauth2/file.developer_keys.md),
and [OAuth endpoints and redirect requirements](https://developerdocs.instructure.com/services/canvas/oauth2/file.oauth_endpoints.md).

---

# License

EmberGuide is available under the [MIT License](LICENSE). You may use, modify,
and distribute it, subject to the license terms. The software is provided
without warranty.

---

# Disclaimer

This is an independent personal project using the Canvas LMS API.

It is not affiliated with, endorsed by, or maintained by Instructure or any school district.

Canvas remains the authoritative source for assignments, submissions, grades, due dates, and teacher feedback. Always verify important academic information directly in Canvas.
