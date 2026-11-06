MailDock 1.0
============
A native Mac app for Gmail, with every account open in one sidebar.
Requires macOS 14 Sonoma or later. Works on Apple silicon and Intel.

INSTALL
1. Unzip MailDock.zip into Downloads.
2. Open Terminal and run:

     bash ~/Downloads/MailDock/install.command

   The app is compiled on your Mac, which takes a few minutes the first time.
   It goes into the Applications folder inside your home folder and opens.
   Drag it to the Dock.

   The finished app runs on both chip types. Copy it from ~/Applications to
   your other Mac, or run the installer there.

CONNECT TO GOOGLE (once, about 10 minutes)
Google requires a mail app to use a sign-in client. For a personal app like
this one, the client belongs to you.

1. Go to console.cloud.google.com and create a project called MailDock.
2. Open APIs & Services > Library, search for Gmail API, and click Enable.
3. Open Google Auth Platform and click Get started.
   App name: MailDock. Support and contact email: your own.
   Audience: External.
4. Open Audience and click Publish app, so the status says In production.
   DON'T SKIP THIS: in Testing status, Google signs you out every 7 days.
5. Open Data Access > Add or remove scopes. Add this scope and save:
     https://www.googleapis.com/auth/gmail.modify
6. Open Clients > Create client.
   Application type: Desktop app. Name: MailDock.
   Download the JSON file.
7. In MailDock, click "Choose the Downloaded JSON File…" and pick that file.

ADD YOUR ACCOUNTS
Click Add Account and repeat for each Gmail address.

Your browser opens for this one step, because Google doesn't allow its
sign-in page inside apps. It will say "Google hasn't verified this app".
That's expected, since the app is yours. Click Advanced, then Go to MailDock.
Google allows this for personal apps with fewer than 100 users.

Once signed in, MailDock doesn't need the browser. A work or school Google
account may be blocked by its administrator.

USING IT
- The sidebar lists All Inboxes, then each account with its folders and labels.
- Search works just like Gmail: from:ann has:attachment older_than:1y
- Inbox tabs (Primary, Promotions and so on) are above the message list.
- Images stay hidden until you click Show Images, so senders can't tell you
  opened their message. Links open in your default browser when clicked.
- New mail is checked for every 60 seconds while the app is open.

SHORTCUTS
With the message list selected, Gmail's keys work:
  c new   r reply   a reply all   f forward   e archive   # trash
  ! spam  s star    u unread      j next      k previous
Menu shortcuts:
  Cmd-N new message    Cmd-R reply    Shift-Cmd-R reply all
  Shift-Cmd-F forward  Cmd-E archive  Cmd-Delete trash
  Shift-Cmd-N check for new mail      Cmd-Return send (in a message window)

GOOD TO KNOW
- Emails appear as native text and pictures, with no web engine. That's safer
  and matches your "no web browser" request, but heavily designed marketing
  emails won't look the way they do in Gmail.
- New messages are plain text, without bold or fonts.
- Trash is as far as delete goes. Gmail empties it after 30 days. MailDock
  deliberately doesn't ask for permission to erase mail permanently.
- Mail comes from Gmail live. Recent message lists are saved so they appear
  instantly, but it isn't a full offline copy of your mailbox.
- Sign-in tokens are kept in the macOS Keychain. After you rebuild the app,
  macOS may ask once to allow Keychain access. Click Always Allow.
- Mail goes only between your Mac and Google. There is no MailDock server.

IF SOMETHING GOES WRONG
Build problems are logged in ~/Library/Logs/MailDock-install.log
Send that file to Claude, along with a screenshot of any error in the app.

FOR DEVELOPERS
Sources/Core  Gmail, sign-in, email rendering and app state
Sources/App   SwiftUI interface
Tests         Run with: swift test
