# PowerShell Chat GUI for LLM API

This tool provides a graphical user interface for interacting with the Ollama API through the ApiProxy server, allowing you to:

- Send prompts to the API and view responses
- Maintain conversation context between messages
- Configure API parameters through a settings dialog
- See relevant context sources used to enhance responses

## Prerequisites

- PowerShell 7.0 or later
- Windows operating system (for Windows Forms support)
- ApiProxy.ps1 running and configured correctly

## Setup and Usage

1. First, make sure the API proxy is running:
   ```powershell
   # Start the API proxy with default settings (localhost:8081)
   .\ApiProxy.ps1
   ```

2. Once the API proxy is running, start the Chat GUI:
   ```powershell
   .\ChatGUI.ps1
   ```

3. The application window will appear with:
   - A chat history display at the top
   - A text input area at the bottom
   - Control buttons for sending messages, accessing settings, and clearing the chat

4. Type your message in the input box and press Enter or click the Send button to send it to the API.
   The response will appear in the chat history area.

## Features

### Conversation Context

The GUI maintains conversation context between messages, allowing for coherent multi-turn conversations.
Each message you send includes all previous messages in the conversation, enabling the model to provide
contextually relevant responses.

### Context-Enhanced Responses

When using the ApiProxy, responses are automatically enhanced with relevant information from your
ChromaDB database. The GUI displays which documents were used as context sources at the end of each
response, along with their relevance scores.

### Configurable Settings

Click the "Settings" button to access configuration options:

- **API URL**: The URL of the chat API endpoint (default: http://localhost:8081/api/chat)
- **Model**: The Ollama model to use for responses (default: llama3)
- **Max Context Docs**: Maximum number of documents to include as context (default: 5)
- **Relevance Threshold**: Minimum similarity score for including documents as context (default: 0.75)
- **System Prompt**: The system message that defines the assistant's behavior

### Input Controls

- Press Enter to send a message
- Press Shift+Enter to add a new line without sending
- Click "Clear Chat" to start a new conversation

## Troubleshooting

- If you receive connection errors, ensure ApiProxy.ps1 is running
- For model-specific errors, check that the model specified in settings is available in your Ollama installation
- If no context documents are displayed, verify your ChromaDB database is properly set up and populated

## Example Workflow

1. Start the API proxy:
   ```powershell
   .\ApiProxy.ps1 -ChromaDbPath ".\chroma_db"
   ```

2. Start the Chat GUI:
   ```powershell
   .\ChatGUI.ps1
   ```

3. Configure the GUI through the Settings button (optional)

4. Begin chatting with the model, receiving responses enhanced with context from your documents
