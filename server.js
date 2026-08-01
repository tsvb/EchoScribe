import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import { exec } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;

// Serve static files from the 'public' directory
app.use(express.static(path.join(__dirname, 'public')));

// Fallback all routes to index.html (SPA routing)
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

const server = app.listen(PORT, () => {
  const localUrl = `http://localhost:${PORT}`;
  
  // Immersive terminal dashboard greeting
  console.clear();
  console.log('\x1b[35m%s\x1b[0m', '=========================================================');
  console.log('\x1b[36m%s\x1b[0m', '          🎙️   LOCAL MEETING ASSISTANT INITIALIZED  🎙️          ');
  console.log('\x1b[35m%s\x1b[0m', '=========================================================');
  console.log('\x1b[32m%s\x1b[0m', `  🚀 Server is running locally at: ${localUrl}`);
  console.log('\x1b[33m%s\x1b[0m', '  🛡️  Audio is analyzed via the Gemini API with your key; the key stays in your browser and is never sent to this server.');
  console.log('\x1b[35m%s\x1b[0m', '=========================================================');
  console.log('  Press Ctrl+C to terminate the session.');
  console.log('\x1b[35m%s\x1b[0m', '=========================================================');

  // Automatically open the app in the browser on Mac
  exec(`open ${localUrl}`, (err) => {
    if (err) {
      console.log(`\n  ℹ️  Please open ${localUrl} manually in your web browser.`);
    } else {
      console.log('\n  ✨ Automatically opened browser to Meeting Assistant.');
    }
  });
});
