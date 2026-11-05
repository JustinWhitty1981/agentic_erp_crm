import { useState, useRef, useEffect } from 'react'
import { Message } from './types'
import Chat from './Chat'
import './Chat.css'

const API_BASE = window.location.origin
const API_KEY = import.meta.env.VITE_API_KEY || (window as any).API_KEY || ''

function App() {
  const [messages, setMessages] = useState<Message[]>([
    {
      id: '1',
      role: 'assistant',
      content: 'Inventory control agent. Ask me to:\n\n- **Show what is low** - the shortage list with the database\'s own LOW and CRITICAL verdicts, thresholds, and lead times\n- **Say where stock is** - per warehouse and bin, what is on hand, committed, and in transit\n- **Read an item\'s history** - movements over the window and days of supply, with unknown said as unknown\n- **Value the shelves** - what stock is worth by warehouse and currency, nothing converted silently\n- **Reserve stock** - when you name the item, the quantity, and the order it is held for\n\nA stock check runs on its own every 30 minutes; you can ask what it last found. Whatever I answer, the run itself is recorded: the tools I called, in order, and which records the answer came from.',
      timestamp: new Date()
    }
  ])
  const [isLoading, setIsLoading] = useState(false)
  const [statusMessage, setStatusMessage] = useState<string | null>(null)
  const [isStreamingText, setIsStreamingText] = useState(false)
  const messagesEndRef = useRef<HTMLDivElement>(null)

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }

  useEffect(() => {
    scrollToBottom()
  }, [messages])

  const sendMessage = async (text: string) => {
    const userMessage: Message = {
      id: Date.now().toString(),
      role: 'user',
      content: text,
      timestamp: new Date()
    }

    const assistantMsgId = (Date.now() + 1).toString()
    setMessages(prev => [...prev, userMessage])
    setIsLoading(true)
    setStatusMessage('Thinking...')
    setIsStreamingText(false)

    let hasCreatedAssistantMessage = false

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
      }
      if (API_KEY) {
        headers['X-API-Key'] = API_KEY
      }

      const response = await fetch(`${API_BASE}/api/chat/stream`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          message: text,
          thread_id: 'default'
        })
      })

      if (!response.ok || !response.body) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { value, done } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split('\n')
        buffer = lines.pop() || ''

        for (const line of lines) {
          const trimmed = line.trim()
          if (!trimmed.startsWith('data:')) continue

          const jsonStr = trimmed.replace(/^data:\s*/, '')
          if (!jsonStr) continue

          try {
            const data = JSON.parse(jsonStr)

            if (data.type === 'status') {
              if (data.content) {
                setStatusMessage(data.content)
              }
              setIsStreamingText(false)
            } else if (data.type === 'token') {
              if (!data.content) continue
              setIsStreamingText(true)

              if (!hasCreatedAssistantMessage) {
                hasCreatedAssistantMessage = true
                const newAssistantMsg: Message = {
                  id: assistantMsgId,
                  role: 'assistant',
                  content: data.content,
                  timestamp: new Date()
                }
                setMessages(prev => [...prev, newAssistantMsg])
              } else {
                setMessages(prev =>
                  prev.map(msg =>
                    msg.id === assistantMsgId
                      ? { ...msg, content: msg.content + data.content }
                      : msg
                  )
                )
              }
            } else if (data.type === 'done') {
              setStatusMessage(null)
              setIsStreamingText(false)
            } else if (data.type === 'error') {
              setStatusMessage(null)
              setIsStreamingText(false)
              const errText = `Sorry, I encountered an error: ${data.content}`
              if (!hasCreatedAssistantMessage) {
                hasCreatedAssistantMessage = true
                setMessages(prev => [
                  ...prev,
                  {
                    id: assistantMsgId,
                    role: 'assistant',
                    content: errText,
                    timestamp: new Date()
                  }
                ])
              } else {
                setMessages(prev =>
                  prev.map(msg =>
                    msg.id === assistantMsgId
                      ? { ...msg, content: msg.content + `\n\n[${errText}]` }
                      : msg
                  )
                )
              }
            }
          } catch (e) {
            console.error('Error parsing SSE event', e, jsonStr)
          }
        }
      }
    } catch (error) {
      const errorContent = `Sorry, I encountered an error: ${error instanceof Error ? error.message : 'Unknown error'}`
      if (!hasCreatedAssistantMessage) {
        setMessages(prev => [
          ...prev,
          {
            id: assistantMsgId,
            role: 'assistant',
            content: errorContent,
            timestamp: new Date()
          }
        ])
      } else {
        setMessages(prev =>
          prev.map(msg =>
            msg.id === assistantMsgId
              ? { ...msg, content: msg.content ? msg.content : errorContent }
              : msg
          )
        )
      }
    } finally {
      setIsLoading(false)
      setStatusMessage(null)
      setIsStreamingText(false)
    }
  }

  return (
    <Chat
      messages={messages}
      isLoading={isLoading}
      statusMessage={statusMessage}
      isStreamingText={isStreamingText}
      onSend={sendMessage}
    />
  )
}

export default App