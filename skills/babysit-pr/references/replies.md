# Replies on a pull request

Nothing is posted, answered or resolved without the owner's say
(`../SKILL.md`, "Treating what arrives"). Until then a reply is a draft in
your report, under the link of the thread it answers. This page says how to
write the draft, and how to post it once the owner agrees.

## Writing a reply

- Lead with the conclusion: fixed, declined, or disagree.
- Cite what backs it: the commit, `file:line`, the check, the reproduction.
- Say which part you verified and which part is your judgment.
- Leave out thanks, status narration and a summary of the comment you are
  answering.

Bad:

> Thanks for the review! I looked into this and made some changes to the
> retry logic, which should address the concern.

Good:

> Fixed in `9ab0cde`. `SaveQueue.flush` now drops a save when a newer one for
> the same note is queued (`save-queue.ts:41`). The new test
> `drops superseded saves` fails without the change. I did not check the
> import path, which uses its own queue.

## Posting, on the owner's say

The owner's yes covers the draft they read. A reply you changed afterwards
needs a new yes.

1. Start the comment with one line saying who wrote it, then the reply:

   ```md
   > [!NOTE]
   > <model> replying on behalf of <the owner's name or GitHub login>

   <the reply>
   ```

   Name the model as the harness reports it. If it reports none, name the
   harness; never guess. One note, nothing else in it, and no signature at
   the end. Pull request descriptions, commit messages and text the owner
   asked to post word for word do not get the note.
2. Read the whole comment for secrets and private details, quotes and
   attachments included (`../../file-pr/SKILL.md`, "Check before you
   submit").
3. Post it, and check that GitHub returned the comment's URL. No URL means
   it was not posted.
4. Resolve a thread only after its reply was posted, and only when the
   owner's yes covered resolving.
