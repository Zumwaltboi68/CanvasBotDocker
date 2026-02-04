# ==========================================
# Canvas Quiz Bot - Render-Optimized Dockerfile
# Production-ready build with multi-stage support
# ==========================================

FROM node:20-bookworm-slim

# Metadata
LABEL maintainer="Canvas Quiz Bot"
LABEL description="Canvas Quiz Bot with noVNC GUI support - Render optimized"
LABEL version="2.0.0"

# ==========================================
# Environment Configuration
# ==========================================
ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    NODE_ENV=production \
    RENDER=true \
    PORT=10000 \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ==========================================
# System Dependencies Installation
# ==========================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Chromium and dependencies
    chromium \
    chromium-driver \
    chromium-sandbox \
    # X11 and VNC stack
    xvfb \
    x11vnc \
    # noVNC and websockify
    novnc \
    websockify \
    python3-numpy \
    # Window manager
    fluxbox \
    # Essential utilities
    curl \
    wget \
    ca-certificates \
    gnupg \
    # Fonts for better rendering
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-noto-cjk \
    # Process management
    supervisor \
    # Cleanup to reduce image size
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && rm -rf /usr/share/doc/* /usr/share/man/*

# ==========================================
# Application Setup
# ==========================================
WORKDIR /app

# Copy package files for dependency installation
COPY package*.json ./

# Install Node.js dependencies with production optimizations
RUN npm ci --only=production --no-audit --no-fund \
    && npm cache clean --force

# Copy application files
COPY server.js ./
COPY public ./public

# Alternative: If files don't exist, create them inline
# This section creates the files if they're not in the build context
RUN if [ ! -f "package.json" ]; then \
    cat > package.json << 'EOF'
{
  "name": "canvas-quiz-bot",
  "version": "2.0.0",
  "type": "module",
  "description": "Automated Canvas quiz solver with GUI support - Render optimized",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node server.js"
  },
  "keywords": ["canvas", "quiz", "automation", "puppeteer", "render"],
  "author": "Canvas Quiz Bot",
  "license": "MIT",
  "dependencies": {
    "express": "^4.18.2",
    "puppeteer": "^21.6.1",
    "groq-sdk": "^0.3.3"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
EOF
    npm install --production --no-audit --no-fund; \
fi

# Create server.js if it doesn't exist
RUN if [ ! -f "server.js" ]; then \
    cat > server.js << 'SERVEREOF'
import express from 'express';
import puppeteer from 'puppeteer';
import Groq from 'groq-sdk';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 10000;

app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));
app.use(express.static('public'));

// Store browser instance and active sessions
let browserInstance = null;
const activeSessions = new Map();

// Detect environment
const isRender = process.env.RENDER === 'true';
const isProduction = process.env.NODE_ENV === 'production';

console.log('Environment:', { isRender, isProduction, PORT });

// Initialize Groq client
const initGroqClient = (apiKey) => {
  return new Groq({ apiKey });
};

// Get or create browser instance
async function getBrowser() {
  if (!browserInstance) {
    const launchOptions = {
      headless: false,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-web-security',
        '--disable-features=IsolateOrigins,site-per-process',
        '--disable-dev-shm-usage',
        '--disable-accelerated-2d-canvas',
        '--disable-gpu',
        '--no-first-run',
        '--no-zygote',
        '--single-process',
        '--disable-extensions',
        '--disable-background-networking',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows',
        '--disable-breakpad',
        '--disable-client-side-phishing-detection',
        '--disable-component-extensions-with-background-pages',
        '--disable-default-apps',
        '--disable-hang-monitor',
        '--disable-ipc-flooding-protection',
        '--disable-popup-blocking',
        '--disable-prompt-on-repost',
        '--disable-renderer-backgrounding',
        '--disable-sync',
        '--force-color-profile=srgb',
        '--metrics-recording-only',
        '--safebrowsing-disable-auto-update',
        '--password-store=basic',
        '--use-mock-keychain',
        `--display=${process.env.DISPLAY || ':99'}`
      ]
    };

    // Use system Chromium
    const executablePath = process.env.PUPPETEER_EXECUTABLE_PATH || '/usr/bin/chromium';
    launchOptions.executablePath = executablePath;
    console.log(`Launching browser at: ${executablePath}`);

    try {
      browserInstance = await puppeteer.launch(launchOptions);
      console.log('✓ Browser instance created successfully');
      
      browserInstance.on('disconnected', () => {
        console.log('Browser disconnected, clearing instance');
        browserInstance = null;
      });
    } catch (error) {
      console.error('✗ Failed to launch browser:', error);
      throw error;
    }
  }
  return browserInstance;
}

// Extract quiz questions from Canvas page
async function extractQuizQuestions(page) {
  return await page.evaluate(() => {
    const questions = [];
    const questionElements = document.querySelectorAll('.question, .quiz_question, [class*="question"]');
    
    questionElements.forEach((questionEl, index) => {
      try {
        const questionTextEl = questionEl.querySelector('.question_text, .text, [class*="question_text"]');
        const questionText = questionTextEl ? questionTextEl.innerText.trim() : '';
        
        if (!questionText) return;
        
        const questionData = {
          index,
          text: questionText,
          type: 'unknown',
          options: [],
          questionElement: null
        };
        
        const multipleChoiceOptions = questionEl.querySelectorAll('input[type="radio"]');
        const checkboxOptions = questionEl.querySelectorAll('input[type="checkbox"]');
        const textareaInput = questionEl.querySelector('textarea');
        const textInput = questionEl.querySelector('input[type="text"]');
        
        if (multipleChoiceOptions.length > 0) {
          questionData.type = 'multiple_choice';
          multipleChoiceOptions.forEach((radio) => {
            const label = radio.closest('label') || 
                         document.querySelector(`label[for="${radio.id}"]`) ||
                         radio.parentElement;
            const optionText = label ? label.innerText.trim() : '';
            questionData.options.push({
              text: optionText,
              value: radio.value,
              id: radio.id
            });
          });
        } else if (checkboxOptions.length > 0) {
          questionData.type = 'multiple_select';
          checkboxOptions.forEach((checkbox) => {
            const label = checkbox.closest('label') || 
                         document.querySelector(`label[for="${checkbox.id}"]`) ||
                         checkbox.parentElement;
            const optionText = label ? label.innerText.trim() : '';
            questionData.options.push({
              text: optionText,
              value: checkbox.value,
              id: checkbox.id
            });
          });
        } else if (textareaInput) {
          questionData.type = 'essay';
          questionData.inputId = textareaInput.id || `textarea-${index}`;
        } else if (textInput) {
          questionData.type = 'short_answer';
          questionData.inputId = textInput.id || `text-${index}`;
        }
        
        questions.push(questionData);
      } catch (error) {
        console.error('Error extracting question:', error);
      }
    });
    
    return questions;
  });
}

// Get answer from Groq API
async function getAnswerFromGroq(groqClient, question, options = []) {
  try {
    let prompt = '';
    
    if (question.type === 'multiple_choice') {
      prompt = `Answer this multiple choice question. Return ONLY the letter (A, B, C, D, etc.) of the correct answer, nothing else.\n\nQuestion: ${question.text}\n\nOptions:\n`;
      options.forEach((opt, idx) => {
        prompt += `${String.fromCharCode(65 + idx)}. ${opt.text}\n`;
      });
    } else if (question.type === 'multiple_select') {
      prompt = `Answer this multiple select question. Return ONLY the letters (e.g., "A,C,D") of ALL correct answers separated by commas, nothing else.\n\nQuestion: ${question.text}\n\nOptions:\n`;
      options.forEach((opt, idx) => {
        prompt += `${String.fromCharCode(65 + idx)}. ${opt.text}\n`;
      });
    } else if (question.type === 'essay') {
      prompt = `Provide a comprehensive essay answer to this question:\n\n${question.text}\n\nWrite a detailed, well-structured response.`;
    } else if (question.type === 'short_answer') {
      prompt = `Provide a concise, direct answer to this question:\n\n${question.text}`;
    } else {
      prompt = `Answer this question:\n\n${question.text}`;
    }
    
    const completion = await groqClient.chat.completions.create({
      messages: [
        { role: 'system', content: 'You are a helpful assistant that provides accurate answers to quiz questions. Be concise and precise.' },
        { role: 'user', content: prompt }
      ],
      model: 'llama-3.1-70b-versatile',
      temperature: 0.2,
      max_tokens: question.type === 'essay' ? 1000 : 200
    });
    
    return completion.choices[0]?.message?.content?.trim() || '';
  } catch (error) {
    console.error('Groq API error:', error);
    throw error;
  }
}

// Fill answer on page
async function fillAnswer(page, question, answer) {
  return await page.evaluate(({ question, answer }) => {
    try {
      if (question.type === 'multiple_choice') {
        const letterMatch = answer.match(/^([A-Z])/);
        if (letterMatch) {
          const index = letterMatch[1].charCodeAt(0) - 65;
          if (question.options[index]) {
            const radio = document.getElementById(question.options[index].id);
            if (radio) {
              radio.checked = true;
              radio.dispatchEvent(new Event('change', { bubbles: true }));
              return true;
            }
          }
        }
      } else if (question.type === 'multiple_select') {
        const letters = answer.split(',').map(l => l.trim());
        letters.forEach(letter => {
          const index = letter.charCodeAt(0) - 65;
          if (question.options[index]) {
            const checkbox = document.getElementById(question.options[index].id);
            if (checkbox) {
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));
            }
          }
        });
        return true;
      } else if (question.type === 'essay' || question.type === 'short_answer') {
        const input = document.getElementById(question.inputId) || 
                     document.querySelector(`textarea, input[type="text"]`);
        if (input) {
          input.value = answer;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        }
      }
      return false;
    } catch (error) {
      console.error('Error filling answer:', error);
      return false;
    }
  }, { question, answer });
}

// API Routes
app.get('/', (req, res) => {
  res.send(`
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canvas Quiz Bot</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 900px; margin: 0 auto; }
        .card {
            background: white;
            border-radius: 12px;
            padding: 30px;
            margin-bottom: 20px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
        }
        h1 {
            color: #667eea;
            margin-bottom: 10px;
            font-size: 2.5em;
        }
        .subtitle {
            color: #666;
            margin-bottom: 30px;
        }
        .input-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 8px;
            font-weight: 600;
            color: #333;
        }
        input[type="text"], input[type="password"] {
            width: 100%;
            padding: 12px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        input:focus {
            outline: none;
            border-color: #667eea;
        }
        .button {
            background: #667eea;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s;
            margin-right: 10px;
            margin-bottom: 10px;
        }
        .button:hover:not(:disabled) {
            background: #5568d3;
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }
        .button:disabled {
            background: #ccc;
            cursor: not-allowed;
        }
        .button.secondary {
            background: #10b981;
        }
        .button.secondary:hover:not(:disabled) {
            background: #059669;
        }
        .button.danger {
            background: #ef4444;
        }
        .button.danger:hover:not(:disabled) {
            background: #dc2626;
        }
        .status {
            padding: 12px;
            border-radius: 8px;
            margin-bottom: 20px;
            display: none;
        }
        .status.success { background: #d1fae5; color: #065f46; }
        .status.error { background: #fee2e2; color: #991b1b; }
        .status.info { background: #dbeafe; color: #1e40af; }
        .loading {
            display: inline-block;
            width: 20px;
            height: 20px;
            border: 3px solid rgba(255,255,255,.3);
            border-radius: 50%;
            border-top-color: white;
            animation: spin 1s ease-in-out infinite;
            margin-left: 10px;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
        .question-item, .result-item {
            background: #f9fafb;
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 15px;
        }
        .option {
            padding: 8px;
            margin: 5px 0;
            background: white;
            border-radius: 4px;
        }
        .checkbox-group {
            display: flex;
            align-items: center;
            margin-bottom: 20px;
        }
        .checkbox-group input {
            margin-right: 10px;
            width: 20px;
            height: 20px;
        }
        .info-box {
            background: #f0f9ff;
            border-left: 4px solid #0284c7;
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 4px;
        }
        .vnc-link {
            display: inline-block;
            background: #f59e0b;
            color: white;
            padding: 10px 20px;
            border-radius: 8px;
            text-decoration: none;
            margin-top: 10px;
            font-weight: 600;
        }
        .vnc-link:hover {
            background: #d97706;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h1>🎓 Canvas Quiz Bot</h1>
            <p class="subtitle">Automated quiz solving with AI assistance</p>
            
            <div class="info-box">
                <strong>📺 VNC Access:</strong> View the browser in real-time<br>
                <a href="/novnc" class="vnc-link" target="_blank">Open VNC Viewer (Port 6080)</a>
            </div>

            <div id="status" class="status"></div>

            <div class="input-group">
                <label>Groq API Key:</label>
                <input type="password" id="groqKey" placeholder="Enter your Groq API key">
            </div>

            <button class="button" id="startBtn" onclick="startSession()">
                🚀 Start New Session
            </button>
            <button class="button secondary" id="navigateBtn" onclick="navigateToCanvas()" disabled>
                🌐 Navigate to Canvas
            </button>
            <button class="button" id="extractBtn" onclick="extractQuestions()" disabled>
                📝 Extract Questions
            </button>
            <button class="button secondary" id="solveBtn" onclick="solveQuiz()" disabled>
                🤖 Solve Quiz
            </button>
            <button class="button danger" id="closeBtn" onclick="closeSession()" disabled>
                ❌ Close Session
            </button>

            <div class="checkbox-group">
                <input type="checkbox" id="autoSubmit">
                <label for="autoSubmit" style="margin-bottom: 0;">Auto-submit quiz after solving</label>
            </div>

            <div class="input-group">
                <label>Canvas Quiz URL:</label>
                <input type="text" id="canvasUrl" placeholder="https://canvas.instructure.com/courses/...">
            </div>
        </div>

        <div class="card" id="questionsCard" style="display: none;">
            <h2>📋 Extracted Questions</h2>
            <div id="questionsList"></div>
        </div>

        <div class="card" id="resultsCard" style="display: none;">
            <h2>✅ Results</h2>
            <div id="resultsList"></div>
        </div>
    </div>

    <script>
        let sessionId = null;

        function showStatus(message, type) {
            const status = document.getElementById('status');
            status.textContent = message;
            status.className = \`status \${type}\`;
            status.style.display = 'block';
        }

        function setLoading(isLoading, message = '') {
            const buttons = document.querySelectorAll('.button');
            buttons.forEach(btn => btn.disabled = isLoading);
            if (isLoading && message) showStatus(message, 'info');
        }

        async function startSession() {
            const groqKey = document.getElementById('groqKey').value.trim();
            if (!groqKey) {
                showStatus('Please enter your Groq API key', 'error');
                return;
            }

            setLoading(true, 'Starting session...');

            try {
                const response = await fetch('/api/start-session', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ groqApiKey: groqKey })
                });

                const data = await response.json();

                if (response.ok) {
                    sessionId = data.sessionId;
                    showStatus('✓ Session started! Browser ready.', 'success');
                    document.getElementById('navigateBtn').disabled = false;
                    document.getElementById('closeBtn').disabled = false;
                    document.getElementById('startBtn').disabled = true;
                } else {
                    showStatus(\`Error: \${data.error}\`, 'error');
                }
            } catch (error) {
                showStatus(\`Network error: \${error.message}\`, 'error');
            } finally {
                setLoading(false);
            }
        }

        async function navigateToCanvas() {
            const url = document.getElementById('canvasUrl').value.trim();
            if (!url) {
                showStatus('Please enter a Canvas URL', 'error');
                return;
            }

            setLoading(true, 'Navigating to Canvas...');

            try {
                const response = await fetch('/api/navigate', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sessionId, url })
                });

                const data = await response.json();

                if (response.ok) {
                    showStatus('✓ Navigated to Canvas page!', 'success');
                    document.getElementById('extractBtn').disabled = false;
                } else {
                    showStatus(\`Error: \${data.error}\`, 'error');
                }
            } catch (error) {
                showStatus(\`Network error: \${error.message}\`, 'error');
            } finally {
                setLoading(false);
            }
        }

        async function extractQuestions() {
            setLoading(true, 'Extracting questions...');

            try {
                const response = await fetch('/api/extract-questions', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sessionId })
                });

                const data = await response.json();

                if (response.ok) {
                    showStatus(\`✓ Found \${data.count} questions!\`, 'success');
                    displayQuestions(data.questions);
                    document.getElementById('solveBtn').disabled = false;
                } else {
                    showStatus(\`Error: \${data.error}\`, 'error');
                }
            } catch (error) {
                showStatus(\`Network error: \${error.message}\`, 'error');
            } finally {
                setLoading(false);
            }
        }

        function displayQuestions(questions) {
            const card = document.getElementById('questionsCard');
            const list = document.getElementById('questionsList');

            list.innerHTML = questions.map((q, i) => \`
                <div class="question-item">
                    <h4>Question \${i + 1} (\${q.type})</h4>
                    <p><strong>\${q.text}</strong></p>
                    \${q.options.length > 0 ? \`
                        <div>
                            \${q.options.map((opt, j) => \`
                                <div class="option">\${String.fromCharCode(65 + j)}. \${opt.text}</div>
                            \`).join('')}
                        </div>
                    \` : ''}
                </div>
            \`).join('');

            card.style.display = 'block';
        }

        async function solveQuiz() {
            const autoSubmit = document.getElementById('autoSubmit').checked;
            setLoading(true, 'Solving quiz with AI...');

            try {
                const response = await fetch('/api/solve-quiz', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sessionId, autoSubmit })
                });

                const data = await response.json();

                if (response.ok) {
                    showStatus(
                        \`✓ Solved \${data.answeredQuestions}/\${data.totalQuestions} questions!\` +
                        (autoSubmit ? ' Quiz submitted!' : ''),
                        'success'
                    );
                    displayResults(data.results);
                } else {
                    showStatus(\`Error: \${data.error}\`, 'error');
                }
            } catch (error) {
                showStatus(\`Network error: \${error.message}\`, 'error');
            } finally {
                setLoading(false);
            }
        }

        function displayResults(results) {
            const card = document.getElementById('resultsCard');
            const list = document.getElementById('resultsList');

            list.innerHTML = results.map((r, i) => \`
                <div class="result-item \${r.error ? 'error' : ''}">
                    <strong>Q\${i + 1}:</strong> \${r.questionText}<br>
                    <strong>Type:</strong> \${r.questionType}<br>
                    \${r.error ? 
                        \`<strong style="color: #ef4444;">Error:</strong> \${r.error}\` :
                        \`<strong>Answer:</strong> \${r.answer} \${r.filled ? '✓' : '✗'}\`
                    }
                </div>
            \`).join('');

            card.style.display = 'block';
        }

        async function closeSession() {
            setLoading(true, 'Closing session...');

            try {
                const response = await fetch('/api/close-session', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sessionId })
                });

                if (response.ok) {
                    showStatus('✓ Session closed', 'info');
                    sessionId = null;
                    document.getElementById('startBtn').disabled = false;
                    ['navigateBtn', 'extractBtn', 'solveBtn', 'closeBtn'].forEach(id => {
                        document.getElementById(id).disabled = true;
                    });
                }
            } catch (error) {
                showStatus(\`Error: \${error.message}\`, 'error');
            } finally {
                setLoading(false);
            }
        }

        // Health check on load
        fetch('/api/health')
            .then(r => r.json())
            .then(data => console.log('Service health:', data))
            .catch(err => console.error('Health check failed:', err));
    </script>
</body>
</html>
  `);
});

app.get('/api/health', (req, res) => {
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    environment: { isRender, isProduction },
    ports: { http: PORT, vnc: 5900, novnc: 6080 },
    services: {
      chromium: process.env.PUPPETEER_EXECUTABLE_PATH || '/usr/bin/chromium',
      display: process.env.DISPLAY
    }
  });
});

app.post('/api/start-session', async (req, res) => {
  try {
    const { groqApiKey } = req.body;
    if (!groqApiKey) {
      return res.status(400).json({ error: 'Groq API key is required' });
    }

    const browser = await getBrowser();
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 800 });

    const sessionId = Date.now().toString();
    const groqClient = initGroqClient(groqApiKey);

    activeSessions.set(sessionId, { page, groqClient, questions: [] });

    res.json({ 
      success: true, 
      sessionId,
      message: 'Session started successfully'
    });
  } catch (error) {
    console.error('Start session error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/navigate', async (req, res) => {
  try {
    const { sessionId, url } = req.body;
    const session = activeSessions.get(sessionId);

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    await session.page.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });
    await session.page.waitForTimeout(2000);

    res.json({ success: true });
  } catch (error) {
    console.error('Navigate error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/extract-questions', async (req, res) => {
  try {
    const { sessionId } = req.body;
    const session = activeSessions.get(sessionId);

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    const questions = await extractQuizQuestions(session.page);
    session.questions = questions;

    res.json({ 
      success: true, 
      questions,
      count: questions.length
    });
  } catch (error) {
    console.error('Extract questions error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/solve-quiz', async (req, res) => {
  try {
    const { sessionId, autoSubmit = false } = req.body;
    const session = activeSessions.get(sessionId);

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    if (!session.questions || session.questions.length === 0) {
      return res.status(400).json({ error: 'No questions extracted yet' });
    }

    const results = [];

    for (const question of session.questions) {
      try {
        const answer = await getAnswerFromGroq(session.groqClient, question, question.options);
        const filled = await fillAnswer(session.page, question, answer);
        
        results.push({
          questionText: question.text,
          questionType: question.type,
          answer,
          filled
        });

        await session.page.waitForTimeout(500);
      } catch (error) {
        results.push({
          questionText: question.text,
          questionType: question.type,
          error: error.message
        });
      }
    }

    if (autoSubmit) {
      try {
        await session.page.evaluate(() => {
          const submitButton = document.querySelector('button[type="submit"], input[type="submit"], .submit_quiz_button');
          if (submitButton) submitButton.click();
        });
      } catch (error) {
        console.error('Auto-submit error:', error);
      }
    }

    res.json({
      success: true,
      results,
      answeredQuestions: results.filter(r => !r.error).length,
      totalQuestions: results.length
    });
  } catch (error) {
    console.error('Solve quiz error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/close-session', async (req, res) => {
  try {
    const { sessionId } = req.body;
    const session = activeSessions.get(sessionId);

    if (session) {
      await session.page.close();
      activeSessions.delete(sessionId);
    }

    res.json({ success: true });
  } catch (error) {
    console.error('Close session error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Cleanup on shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, cleaning up...');
  if (browserInstance) {
    await browserInstance.close();
  }
  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('SIGINT received, cleaning up...');
  if (browserInstance) {
    await browserInstance.close();
  }
  process.exit(0);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(\`
╔════════════════════════════════════════╗
║   Canvas Quiz Bot - Server Running     ║
╚════════════════════════════════════════╝

🌐 Web Interface:  http://0.0.0.0:\${PORT}
📺 noVNC Access:   http://0.0.0.0:6080
🖥️  VNC Direct:     0.0.0.0:5900

Environment: \${isProduction ? 'Production' : 'Development'}
Platform:    \${isRender ? 'Render' : 'Local'}

Ready to solve quizzes! 🎓
  \`);
});
SERVEREOF
fi

# ==========================================
# Supervisor Configuration
# ==========================================
RUN mkdir -p /var/log/supervisor /var/log

RUN cat > /etc/supervisor/conf.d/services.conf << 'SUPERVISOREOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor

[program:xvfb]
command=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset
autostart=true
autorestart=true
priority=10
stdout_logfile=/var/log/xvfb.log
stderr_logfile=/var/log/xvfb_err.log
stdout_logfile_maxbytes=1MB
stderr_logfile_maxbytes=1MB

[program:x11vnc]
command=/usr/bin/x11vnc -display :99 -nopw -listen 0.0.0.0 -xkb -forever -shared -repeat
autostart=true
autorestart=true
priority=20
stdout_logfile=/var/log/x11vnc.log
stderr_logfile=/var/log/x11vnc_err.log
stdout_logfile_maxbytes=1MB
stderr_logfile_maxbytes=1MB

[program:novnc]
command=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080
autostart=true
autorestart=true
priority=30
stdout_logfile=/var/log/novnc.log
stderr_logfile=/var/log/novnc_err.log
stdout_logfile_maxbytes=1MB
stderr_logfile_maxbytes=1MB

[program:fluxbox]
command=/usr/bin/fluxbox -display :99
autostart=true
autorestart=true
priority=40
stdout_logfile=/var/log/fluxbox.log
stderr_logfile=/var/log/fluxbox_err.log
stdout_logfile_maxbytes=1MB
stderr_logfile_maxbytes=1MB
environment=DISPLAY=":99"

[program:node]
command=node /app/server.js
directory=/app
autostart=true
autorestart=true
priority=50
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
environment=DISPLAY=":99",NODE_ENV="production",PORT="%(ENV_PORT)s"
SUPERVISOREOF

# ==========================================
# Startup and Health Check Scripts
# ==========================================
RUN cat > /start.sh << 'STARTEOF'
#!/bin/bash
set -e

echo "=========================================="
echo "  Canvas Quiz Bot - Render Deployment    "
echo "=========================================="
echo ""

# Verify Chromium
if [ -f "/usr/bin/chromium" ]; then
    echo "✓ Chromium found"
    /usr/bin/chromium --version
else
    echo "✗ Chromium not found!"
    exit 1
fi

# Set environment
export DISPLAY=:99
export PORT=${PORT:-10000}

echo "✓ Display: $DISPLAY"
echo "✓ HTTP Port: $PORT"
echo "✓ VNC Port: 5900"
echo "✓ noVNC Port: 6080"
echo ""

# Create log directory
mkdir -p /var/log/supervisor

# Start all services via supervisor
echo "Starting services..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
STARTEOF

RUN chmod +x /start.sh

RUN cat > /healthcheck.sh << 'HEALTHEOF'
#!/bin/bash
PORT=${PORT:-10000}
curl -f http://localhost:$PORT/api/health || exit 1
HEALTHEOF

RUN chmod +x /healthcheck.sh

# ==========================================
# Port Exposure
# ==========================================
# Port 10000: Main HTTP server (Render default)
# Port 5900: VNC server
# Port 6080: noVNC web interface
EXPOSE 10000 5900 6080

# ==========================================
# Health Check Configuration
# ==========================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /healthcheck.sh

# ==========================================
# Volume for persistence (optional)
# ==========================================
VOLUME ["/app/data"]

# ==========================================
# Run as non-root user (commented out for Render compatibility)
# Render may require root for certain operations
# ==========================================
# RUN useradd -m -s /bin/bash appuser && \
#     chown -R appuser:appuser /app
# USER appuser

# ==========================================
# Final Working Directory
# ==========================================
WORKDIR /app

# ==========================================
# Container Entrypoint
# ==========================================
ENTRYPOINT ["/start.sh"]

