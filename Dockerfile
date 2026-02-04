# ==========================================
# Canvas Quiz Bot - Complete Docker Image
# All-in-one production-ready container
# ==========================================

FROM node:20-bookworm-slim

# Metadata
LABEL maintainer="Canvas Quiz Bot"
LABEL description="Complete Canvas Quiz Bot with noVNC GUI support"
LABEL version="1.0.0"

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    NODE_ENV=production \
    RENDER=true \
    PORT=3000 \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Chromium and dependencies
    chromium \
    chromium-driver \
    # X11 and VNC
    xvfb \
    x11vnc \
    # noVNC and websockify
    novnc \
    websockify \
    # Window manager
    fluxbox \
    # Utilities
    curl \
    wget \
    gnupg \
    ca-certificates \
    fonts-liberation \
    fonts-noto-color-emoji \
    # Process management
    supervisor \
    # Cleanup
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create application directory
WORKDIR /app

# Create package.json inline
RUN cat > package.json << 'EOF'
{
  "name": "canvas-quiz-bot",
  "version": "1.0.0",
  "type": "module",
  "description": "Automated Canvas quiz solver with GUI support",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node server.js"
  },
  "keywords": ["canvas", "quiz", "automation", "puppeteer"],
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

# Install Node.js dependencies
RUN npm install --production --no-audit --no-fund

# Create server.js inline
RUN cat > server.js << 'SERVEREOF'
import express from 'express';
import puppeteer from 'puppeteer';
import Groq from 'groq-sdk';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(express.static('public'));

// Store browser instance and active sessions
let browserInstance = null;
const activeSessions = new Map();

// Detect environment
const isRender = process.env.RENDER === 'true';
const isCodespaces = process.env.CODESPACES === 'true';
const isProduction = process.env.NODE_ENV === 'production';

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
        '--disable-extensions'
      ]
    };

    // Use system Chromium
    const executablePath = process.env.PUPPETEER_EXECUTABLE_PATH || '/usr/bin/chromium';
    launchOptions.executablePath = executablePath;
    console.log(`Using Chromium at: ${executablePath}`);

    try {
      browserInstance = await puppeteer.launch(launchOptions);
      console.log('Browser instance created successfully');
    } catch (error) {
      console.error('Failed to launch browser:', error);
      throw error;
    }
  }
  return browserInstance;
}

// Extract quiz questions from Canvas page
async function extractQuizQuestions(page) {
  return await page.evaluate(() => {
    const questions = [];
    
    // Find all question containers
    const questionElements = document.querySelectorAll('.question, .quiz_question, [class*="question"]');
    
    questionElements.forEach((questionEl, index) => {
      try {
        // Extract question text
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
        
        // Detect question type and extract options
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
        {
          role: 'system',
          content: 'You are a helpful assistant that provides accurate answers to quiz questions. Be concise and precise.'
        },
        {
          role: 'user',
          content: prompt
        }
      ],
      model: 'mixtral-8x7b-32768',
      temperature: 0.3,
      max_tokens: question.type === 'essay' ? 1000 : 100
    });
    
    return completion.choices[0]?.message?.content?.trim() || '';
  } catch (error) {
    console.error('Groq API error:', error);
    throw error;
  }
}

// Fill answer in Canvas
async function fillAnswer(page, question, answer) {
  try {
    if (question.type === 'multiple_choice') {
      // Parse letter answer (A, B, C, etc.)
      const answerLetter = answer.trim().toUpperCase().charAt(0);
      const answerIndex = answerLetter.charCodeAt(0) - 65; // A=0, B=1, etc.
      
      if (answerIndex >= 0 && answerIndex < question.options.length) {
        const optionId = question.options[answerIndex].id;
        await page.evaluate((id) => {
          const radio = document.getElementById(id);
          if (radio) {
            radio.click();
            radio.checked = true;
          }
        }, optionId);
        return true;
      }
    } else if (question.type === 'multiple_select') {
      // Parse multiple letters (A,C,D)
      const letters = answer.split(',').map(l => l.trim().toUpperCase().charAt(0));
      const indices = letters.map(l => l.charCodeAt(0) - 65);
      
      for (const index of indices) {
        if (index >= 0 && index < question.options.length) {
          const optionId = question.options[index].id;
          await page.evaluate((id) => {
            const checkbox = document.getElementById(id);
            if (checkbox && !checkbox.checked) {
              checkbox.click();
              checkbox.checked = true;
            }
          }, optionId);
        }
      }
      return true;
    } else if (question.type === 'essay' || question.type === 'short_answer') {
      await page.evaluate((data) => {
        const input = document.getElementById(data.inputId) || 
                     document.querySelector(`textarea, input[type="text"]`);
        if (input) {
          input.value = data.answer;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
        }
      }, { inputId: question.inputId, answer });
      return true;
    }
    
    return false;
  } catch (error) {
    console.error('Error filling answer:', error);
    return false;
  }
}

// API Routes
app.get('/api/health', (req, res) => {
  res.json({
    status: 'healthy',
    environment: {
      isRender,
      isCodespaces,
      isProduction,
      display: process.env.DISPLAY
    },
    chromium: process.env.PUPPETEER_EXECUTABLE_PATH,
    activeSessions: activeSessions.size
  });
});

app.post('/api/start-session', async (req, res) => {
  const { groqApiKey } = req.body;
  
  if (!groqApiKey) {
    return res.status(400).json({ error: 'Groq API key is required' });
  }
  
  try {
    const browser = await getBrowser();
    const page = await browser.newPage();
    
    // Set viewport
    await page.setViewport({ width: 1280, height: 800 });
    
    const sessionId = Date.now().toString();
    const groqClient = initGroqClient(groqApiKey);
    
    activeSessions.set(sessionId, {
      page,
      groqClient,
      questions: [],
      startTime: new Date()
    });
    
    console.log(`Session ${sessionId} started`);
    res.json({
      success: true,
      sessionId,
      message: 'Session started successfully'
    });
  } catch (error) {
    console.error('Error starting session:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/navigate', async (req, res) => {
  const { sessionId, url } = req.body;
  
  if (!sessionId || !url) {
    return res.status(400).json({ error: 'Session ID and URL are required' });
  }
  
  const session = activeSessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'Session not found' });
  }
  
  try {
    await session.page.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });
    res.json({ success: true, message: 'Navigated successfully' });
  } catch (error) {
    console.error('Navigation error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/extract-questions', async (req, res) => {
  const { sessionId } = req.body;
  
  if (!sessionId) {
    return res.status(400).json({ error: 'Session ID is required' });
  }
  
  const session = activeSessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'Session not found' });
  }
  
  try {
    const questions = await extractQuizQuestions(session.page);
    session.questions = questions;
    
    res.json({
      success: true,
      count: questions.length,
      questions: questions.map(q => ({
        index: q.index,
        text: q.text,
        type: q.type,
        options: q.options
      }))
    });
  } catch (error) {
    console.error('Error extracting questions:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/solve-quiz', async (req, res) => {
  const { sessionId, autoSubmit } = req.body;
  
  if (!sessionId) {
    return res.status(400).json({ error: 'Session ID is required' });
  }
  
  const session = activeSessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'Session not found' });
  }
  
  try {
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
        
        // Small delay between questions
        await new Promise(resolve => setTimeout(resolve, 500));
      } catch (error) {
        results.push({
          questionText: question.text,
          questionType: question.type,
          error: error.message
        });
      }
    }
    
    // Auto-submit if requested
    if (autoSubmit) {
      try {
        await session.page.evaluate(() => {
          const submitBtn = document.querySelector('button[type="submit"], input[type="submit"], .submit_quiz_button');
          if (submitBtn) submitBtn.click();
        });
      } catch (error) {
        console.error('Auto-submit error:', error);
      }
    }
    
    res.json({
      success: true,
      totalQuestions: session.questions.length,
      answeredQuestions: results.filter(r => r.filled).length,
      results
    });
  } catch (error) {
    console.error('Error solving quiz:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/close-session', async (req, res) => {
  const { sessionId } = req.body;
  
  if (!sessionId) {
    return res.status(400).json({ error: 'Session ID is required' });
  }
  
  const session = activeSessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'Session not found' });
  }
  
  try {
    await session.page.close();
    activeSessions.delete(sessionId);
    console.log(`Session ${sessionId} closed`);
    res.json({ success: true, message: 'Session closed' });
  } catch (error) {
    console.error('Error closing session:', error);
    res.status(500).json({ error: error.message });
  }
});

// Serve frontend
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`
╔════════════════════════════════════════╗
║     Canvas Quiz Bot - Server Ready     ║
╠════════════════════════════════════════╣
║  Web Interface: http://localhost:${PORT}  ║
║  noVNC GUI:     http://localhost:6080  ║
║  Environment:   ${isProduction ? 'Production' : 'Development'}              ║
╚════════════════════════════════════════╝
  `);
});

// Cleanup on exit
process.on('SIGTERM', async () => {
  console.log('Shutting down gracefully...');
  if (browserInstance) {
    await browserInstance.close();
  }
  process.exit(0);
});
SERVEREOF

# Create public directory
RUN mkdir -p public

# Create index.html inline
RUN cat > public/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Canvas Quiz Bot</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        .header {
            text-align: center;
            color: white;
            margin-bottom: 30px;
        }

        .header h1 {
            font-size: 2.5rem;
            margin-bottom: 10px;
        }

        .header p {
            font-size: 1.1rem;
            opacity: 0.9;
        }

        .card {
            background: white;
            border-radius: 12px;
            padding: 30px;
            margin-bottom: 20px;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
        }

        .card h2 {
            color: #667eea;
            margin-bottom: 20px;
            font-size: 1.5rem;
        }

        .input-group {
            margin-bottom: 20px;
        }

        .input-group label {
            display: block;
            margin-bottom: 8px;
            font-weight: 600;
            color: #333;
        }

        .input-group input {
            width: 100%;
            padding: 12px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 1rem;
            transition: border-color 0.3s;
        }

        .input-group input:focus {
            outline: none;
            border-color: #667eea;
        }

        .checkbox-group {
            display: flex;
            align-items: center;
            margin-bottom: 20px;
        }

        .checkbox-group input[type="checkbox"] {
            width: 20px;
            height: 20px;
            margin-right: 10px;
        }

        .button-group {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }

        button {
            padding: 12px 24px;
            border: none;
            border-radius: 8px;
            font-size: 1rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s;
            flex: 1;
            min-width: 150px;
        }

        button.primary {
            background: #667eea;
            color: white;
        }

        button.primary:hover:not(:disabled) {
            background: #5568d3;
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }

        button.secondary {
            background: #48bb78;
            color: white;
        }

        button.secondary:hover:not(:disabled) {
            background: #38a169;
        }

        button.danger {
            background: #f56565;
            color: white;
        }

        button.danger:hover:not(:disabled) {
            background: #e53e3e;
        }

        button:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }

        .status {
            padding: 15px;
            border-radius: 8px;
            margin-top: 20px;
            font-weight: 500;
            display: none;
        }

        .status.success {
            background: #c6f6d5;
            color: #22543d;
            border-left: 4px solid #48bb78;
        }

        .status.error {
            background: #fed7d7;
            color: #742a2a;
            border-left: 4px solid #f56565;
        }

        .status.info {
            background: #bee3f8;
            color: #2c5282;
            border-left: 4px solid #4299e1;
        }

        .loading {
            display: none;
            text-align: center;
            padding: 20px;
        }

        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #667eea;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 0 auto 10px;
        }

        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }

        .questions-list, .results-list {
            max-height: 400px;
            overflow-y: auto;
        }

        .question-item, .result-item {
            padding: 15px;
            border: 1px solid #e0e0e0;
            border-radius: 8px;
            margin-bottom: 10px;
            background: #f9f9f9;
        }

        .question-item h4 {
            color: #667eea;
            margin-bottom: 10px;
        }

        .option {
            padding: 8px;
            margin: 5px 0;
            background: white;
            border-radius: 4px;
        }

        .result-item.error {
            border-color: #f56565;
            background: #fff5f5;
        }

        .vnc-link {
            display: inline-block;
            padding: 10px 20px;
            background: #48bb78;
            color: white;
            text-decoration: none;
            border-radius: 8px;
            margin-top: 10px;
            font-weight: 600;
        }

        .vnc-link:hover {
            background: #38a169;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🤖 Canvas Quiz Bot</h1>
            <p>AI-Powered Quiz Solver with Live Browser Control</p>
        </div>

        <div class="card">
            <h2>📺 Browser View</h2>
            <p>Access the live browser interface via noVNC:</p>
            <a href="http://localhost:6080/vnc.html" target="_blank" class="vnc-link">
                🖥️ Open Browser View (noVNC)
            </a>
        </div>

        <div class="card">
            <h2>🚀 Setup</h2>
            <div class="input-group">
                <label for="groqApiKey">Groq API Key</label>
                <input type="password" id="groqApiKey" placeholder="Enter your Groq API key">
            </div>
            <div class="button-group">
                <button id="startBtn" class="primary" onclick="startSession()">Start Session</button>
            </div>
        </div>

        <div class="card">
            <h2>🌐 Navigate</h2>
            <div class="input-group">
                <label for="canvasUrl">Canvas Quiz URL</label>
                <input type="url" id="canvasUrl" placeholder="https://canvas.your-school.edu/courses/...">
            </div>
            <div class="button-group">
                <button id="navigateBtn" class="primary" onclick="navigateToCanvas()" disabled>Navigate to Quiz</button>
            </div>
        </div>

        <div class="card">
            <h2>🔍 Extract & Solve</h2>
            <div class="button-group">
                <button id="extractBtn" class="secondary" onclick="extractQuestions()" disabled>Extract Questions</button>
                <button id="solveBtn" class="secondary" onclick="solveQuiz()" disabled>Solve Quiz</button>
            </div>
            <div class="checkbox-group">
                <input type="checkbox" id="autoSubmit">
                <label for="autoSubmit">Automatically submit quiz after solving</label>
            </div>
        </div>

        <div class="card" id="questionsCard" style="display: none;">
            <h2>📝 Questions Found</h2>
            <div id="questionsList" class="questions-list"></div>
        </div>

        <div class="card" id="resultsCard" style="display: none;">
            <h2>✅ Results</h2>
            <div id="resultsList" class="results-list"></div>
        </div>

        <div class="card">
            <h2>⚙️ Session Control</h2>
            <div class="button-group">
                <button id="closeBtn" class="danger" onclick="closeSession()" disabled>Close Session</button>
            </div>
        </div>

        <div id="status" class="status"></div>
        <div id="loading" class="loading">
            <div class="spinner"></div>
            <p id="loadingText">Processing...</p>
        </div>
    </div>

    <script>
        let sessionId = null;

        function showStatus(message, type = 'info') {
            const statusEl = document.getElementById('status');
            statusEl.textContent = message;
            statusEl.className = `status ${type}`;
            statusEl.style.display = 'block';
            
            setTimeout(() => {
                statusEl.style.display = 'none';
            }, 5000);
        }

        function setLoading(isLoading, text = 'Processing...') {
            const loadingEl = document.getElementById('loading');
            const textEl = document.getElementById('loadingText');
            loadingEl.style.display = isLoading ? 'block' : 'none';
            textEl.textContent = text;
        }

        async function startSession() {
            const apiKey = document.getElementById('groqApiKey').value;
            
            if (!apiKey) {
                showStatus('Please enter your Groq API key', 'error');
                return;
            }

            setLoading(true, 'Starting browser session...');

            try {
                const response = await fetch('/api/start-session', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ groqApiKey: apiKey })
                });

                const data = await response.json();

                if (response.ok) {
                    sessionId = data.sessionId;
                    showStatus('✓ Session started! You can now navigate to your Canvas quiz.', 'success');
                    document.getElementById('startBtn').disabled = true;
                    document.getElementById('navigateBtn').disabled = false;
                    document.getElementById('closeBtn').disabled = false;
                } else {
                    showStatus(`Error: ${data.error}`, 'error');
                }
            } catch (error) {
                showStatus(`Network error: ${error.message}`, 'error');
            } finally {
                setLoading(false);
            }
        }

        async function navigateToCanvas() {
            const url = document.getElementById('canvasUrl').value;
            
            if (!url) {
                showStatus('Please enter a Canvas quiz URL', 'error');
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
                    showStatus(`Error: ${data.error}`, 'error');
                }
            } catch (error) {
                showStatus(`Network error: ${error.message}`, 'error');
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
                    showStatus(`✓ Found ${data.count} questions!`, 'success');
                    displayQuestions(data.questions);
                    document.getElementById('solveBtn').disabled = false;
                } else {
                    showStatus(`Error: ${data.error}`, 'error');
                }
            } catch (error) {
                showStatus(`Network error: ${error.message}`, 'error');
            } finally {
                setLoading(false);
            }
        }

        function displayQuestions(questions) {
            const card = document.getElementById('questionsCard');
            const list = document.getElementById('questionsList');

            list.innerHTML = questions.map((q, i) => `
                <div class="question-item">
                    <h4>Question ${i + 1} (${q.type})</h4>
                    <p><strong>${q.text}</strong></p>
                    ${q.options.length > 0 ? `
                        <div>
                            ${q.options.map((opt, j) => `
                                <div class="option">${String.fromCharCode(65 + j)}. ${opt.text}</div>
                            `).join('')}
                        </div>
                    ` : ''}
                </div>
            `).join('');

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
                        `✓ Solved ${data.answeredQuestions}/${data.totalQuestions} questions!` +
                        (autoSubmit ? ' Quiz submitted!' : ''),
                        'success'
                    );
                    displayResults(data.results);
                } else {
                    showStatus(`Error: ${data.error}`, 'error');
                }
            } catch (error) {
                showStatus(`Network error: ${error.message}`, 'error');
            } finally {
                setLoading(false);
            }
        }

        function displayResults(results) {
            const card = document.getElementById('resultsCard');
            const list = document.getElementById('resultsList');

            list.innerHTML = results.map((r, i) => `
                <div class="result-item ${r.error ? 'error' : ''}">
                    <strong>Q${i + 1}:</strong> ${r.questionText}<br>
                    <strong>Type:</strong> ${r.questionType}<br>
                    ${r.error ? 
                        `<strong style="color: #ef4444;">Error:</strong> ${r.error}` :
                        `<strong>Answer:</strong> ${r.answer} ${r.filled ? '✓' : '✗'}`
                    }
                </div>
            `).join('');

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
                showStatus(`Error: ${error.message}`, 'error');
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
HTMLEOF

# Create supervisor configuration inline
RUN cat > /etc/supervisor/conf.d/services.conf << 'SUPERVISOREOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:xvfb]
command=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -ac +extension GLX +render -noreset
autostart=true
autorestart=true
priority=10
stdout_logfile=/var/log/xvfb.log
stderr_logfile=/var/log/xvfb_err.log

[program:x11vnc]
command=/usr/bin/x11vnc -display :99 -nopw -listen 0.0.0.0 -xkb -forever -shared
autostart=true
autorestart=true
priority=20
stdout_logfile=/var/log/x11vnc.log
stderr_logfile=/var/log/x11vnc_err.log

[program:novnc]
command=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080
autostart=true
autorestart=true
priority=30
stdout_logfile=/var/log/novnc.log
stderr_logfile=/var/log/novnc_err.log

[program:fluxbox]
command=/usr/bin/fluxbox -display :99
autostart=true
autorestart=true
priority=40
stdout_logfile=/var/log/fluxbox.log
stderr_logfile=/var/log/fluxbox_err.log
environment=DISPLAY=":99"

[program:node]
command=node /app/server.js
directory=/app
autostart=true
autorestart=true
priority=50
stdout_logfile=/var/log/node.log
stderr_logfile=/var/log/node_err.log
environment=DISPLAY=":99",NODE_ENV="production"
SUPERVISOREOF

# Create startup script
RUN cat > /start.sh << 'STARTEOF'
#!/bin/bash
set -e

echo "=================================="
echo "Canvas Quiz Bot - Starting Services"
echo "=================================="

# Verify Chromium installation
if [ -f "/usr/bin/chromium" ]; then
    echo "✓ Chromium found at /usr/bin/chromium"
    /usr/bin/chromium --version
else
    echo "✗ Chromium not found!"
    exit 1
fi

# Set display
export DISPLAY=:99

# Create log directory
mkdir -p /var/log/supervisor

# Start supervisor with the correct config file
echo "Starting supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
STARTEOF

RUN chmod +x /start.sh

# Create healthcheck script
RUN cat > /healthcheck.sh << 'HEALTHEOF'
#!/bin/bash
curl -f http://localhost:3000/api/health || exit 1
HEALTHEOF

RUN chmod +x /healthcheck.sh

# Expose ports
EXPOSE 3000 5900 6080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /healthcheck.sh

# Set working directory
WORKDIR /app

# Use startup script as entrypoint
ENTRYPOINT ["/start.sh"]
