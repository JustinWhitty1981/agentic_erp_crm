import React, { useState, useRef, useEffect } from 'react'
import { Message } from './types'

interface ChatProps {
  messages: Message[]
  isLoading: boolean
  statusMessage?: string | null
  isStreamingText?: boolean
  onSend: (message: string) => void
}

const Chat: React.FC<ChatProps> = ({ messages, isLoading, statusMessage, isStreamingText, onSend }) => {
  const [input, setInput] = useState('')
  const messagesEndRef = useRef<HTMLDivElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }

  useEffect(() => {
    scrollToBottom()
  }, [messages, statusMessage, isLoading, isStreamingText])

  // Keep focus on textarea whenever messages update or loading finishes
  useEffect(() => {
    if (!isLoading) {
      textareaRef.current?.focus()
    }
  }, [isLoading, messages])

  const adjustHeight = () => {
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto'
      textareaRef.current.style.height = `${Math.min(textareaRef.current.scrollHeight, 160)}px`
    }
  }

  useEffect(() => {
    adjustHeight()
  }, [input])

  const handleSubmit = (e?: React.FormEvent) => {
    if (e) e.preventDefault()
    if (input.trim() && !isLoading) {
      const message = input.trim()
      setInput('')
      if (textareaRef.current) {
        textareaRef.current.style.height = 'auto'
      }
      onSend(message)
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSubmit()
    }
  }

  const formatInline = (text: string) => {
    return (text || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
      .replace(/\*(.+?)\*/g, '<i>$1</i>')
      .replace(/`(.+?)`/g, '<code>$1</code>')
  }

  const formatMessage = (content: string) => {
    if (!content) return { __html: '' }

    const lines = content.trim().split('\n')
    const formattedLines = lines.map((line) => {
      let l = line.trim()

      // Handle headings (###, ##, #)
      if (l.startsWith('### ')) {
        return `<h3 class="msg-heading">${formatInline(l.slice(4))}</h3>`
      }
      if (l.startsWith('## ')) {
        return `<h2 class="msg-heading">${formatInline(l.slice(3))}</h2>`
      }
      if (l.startsWith('# ')) {
        return `<h1 class="msg-heading">${formatInline(l.slice(2))}</h1>`
      }

      // Handle bullet lists (- or *)
      if (l.startsWith('- ') || l.startsWith('* ')) {
        return `<div class="msg-list-item"><span class="msg-bullet">•</span><span>${formatInline(l.slice(2))}</span></div>`
      }

      // Handle numbered lists (e.g. 1. Item)
      const numMatch = l.match(/^(\d+)\.\s+(.*)/)
      if (numMatch) {
        return `<div class="msg-list-item"><span class="msg-number">${numMatch[1]}.</span><span>${formatInline(numMatch[2])}</span></div>`
      }

      // Regular line
      return l ? `<div class="msg-line">${formatInline(l)}</div>` : '<div class="msg-spacer"></div>'
    })

    return { __html: formattedLines.join('') }
  }

  const validMessages = messages.filter(
    (msg) => msg.role === 'user' || (msg.role === 'assistant' && (msg.content || '').trim().length > 0)
  )

  return (
    <div className="chat-container">
      <header className="chat-header">
        <h1>J.A.D.A</h1>
        <p className="subtitle">AI Assistant with Search, Memory & HighByte MCP Tools</p>
      </header>

      <div className="chat-messages">
        {validMessages.map((message) => (
          <div
            key={message.id}
            className={`message ${message.role}`}
          >
            <div className="message-content" dangerouslySetInnerHTML={formatMessage(message.content)} />
            <span className="message-time">
              {message.timestamp.toLocaleTimeString()}
            </span>
          </div>
        ))}
        
        {isLoading && !isStreamingText && (
          <div className="message assistant loading">
            <div className="message-content status-badge-content">
              <span className="typing-indicator">
                <span></span>
                <span></span>
                <span></span>
              </span>
              <span className="status-text">{statusMessage || 'Thinking...'}</span>
            </div>
          </div>
        )}
        
        <div ref={messagesEndRef} />
      </div>

      <form className="chat-input-form" onSubmit={handleSubmit}>
        <textarea
          ref={textareaRef}
          rows={1}
          className="chat-input"
          placeholder="Type your message... (Shift+Enter for new line)"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          disabled={isLoading}
        />
        <button 
          type="submit" 
          className="send-button"
          disabled={isLoading || !input.trim()}
        >
          Send
        </button>
      </form>
    </div>
  )
}

export default Chat