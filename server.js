const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
const helmet = require('helmet');
const path = require('path');
const fs = require('fs');
require('dotenv').config();

const app = express();
const port = process.env.PORT || 8080;

// Configuración de la base de datos PostgreSQL
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Middleware
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'", "https://cdn.tailwindcss.com"],
      scriptSrc: ["'self'", "'unsafe-inline'", "https://cdn.tailwindcss.com"],
      imgSrc: ["'self'", "data:", "https:"],
      connectSrc: ["'self'"]
    }
  }
}));

app.use(cors({
  origin: process.env.NODE_ENV === 'production'
    ? 'https://sasaa-production.up.railway.app'
    : 'http://localhost:8080',
  credentials: true
}));

app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

// Servir archivos estáticos
app.use(express.static(path.join(__dirname, 'public')));

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Express error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// API Routes first (before catch-all route)
app.get('/api/health', async (req, res) => {
  try {
    const result = await pool.query('SELECT NOW()');
    res.json({ 
      status: 'ok', 
      database: 'connected', 
      time: result.rows[0].now,
      environment: process.env.NODE_ENV || 'development'
    });
  } catch (error) {
    console.error('Health check error:', error);
    res.status(500).json({ status: 'error', message: error.message });
  }
});

// API para obtener encuestas
app.get('/api/surveys', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT s.*, 
             (SELECT COUNT(*) FROM survey_questions WHERE survey_id = s.id) as question_count
      FROM surveys s 
      WHERE is_active = true 
      ORDER BY id
    `);
    res.json(result.rows);
  } catch (error) {
    console.error('Error getting surveys:', error);
    res.status(500).json({ error: error.message });
  }
});

// API para obtener preguntas de una encuesta
app.get('/api/surveys/:id/questions', async (req, res) => {
  try {
    const surveyId = req.params.id;
    const result = await pool.query(`
      SELECT * FROM survey_questions 
      WHERE survey_id = $1 
      ORDER BY order_index
    `, [surveyId]);
    res.json(result.rows);
  } catch (error) {
    console.error('Error getting survey questions:', error);
    res.status(500).json({ error: error.message });
  }
});

// API para enviar respuestas de encuesta
app.post('/api/surveys/:id/submit', async (req, res) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    
    const surveyId = req.params.id;
    const { responses, userEmail } = req.body;
    
    // Obtener IP del usuario
    const userIp = req.headers['x-forwarded-for'] || req.connection.remoteAddress || req.ip;
    const userAgent = req.headers['user-agent'] || '';
    
    console.log('Survey submission:', { surveyId, userIp, userAgent, responses });
    
    let userId;
    
    // Crear o obtener usuario temporal basado en IP y email
    const tempEmail = userEmail || `temp_${Date.now()}_${userIp.replace(/\./g, '')}@temp.com`;
    const referralCode = `REF${Date.now().toString().slice(-6)}`;
    
    const userResult = await client.query(`
      INSERT INTO users (email, ip_address, user_agent, referral_code) 
      VALUES ($1, $2, $3, $4) 
      ON CONFLICT (email) DO UPDATE SET 
        ip_address = $2,
        user_agent = $3,
        updated_at = NOW()
      RETURNING id
    `, [tempEmail, userIp, userAgent, referralCode]);
    
    userId = userResult.rows[0].id;
    
    // Verificar si ya completó esta encuesta
    const existingResult = await client.query(`
      SELECT id FROM user_completed_surveys 
      WHERE user_id = $1 AND survey_id = $2
    `, [userId, surveyId]);
    
    if (existingResult.rows.length > 0) {
      throw new Error('Ya has completado esta encuesta');
    }
    
    // Guardar respuestas
    const savedResponses = [];
    for (const [questionKey, answer] of Object.entries(responses)) {
      const questionResult = await client.query(`
        SELECT id FROM survey_questions 
        WHERE survey_id = $1 AND question_key = $2
      `, [surveyId, questionKey]);
      
      if (questionResult.rows.length > 0) {
        await client.query(`
          INSERT INTO user_survey_responses (user_id, survey_id, question_id, answer_text, answer_options)
          VALUES ($1, $2, $3, $4, $5)
        `, [
          userId, 
          surveyId, 
          questionResult.rows[0].id, 
          Array.isArray(answer) ? null : answer, 
          Array.isArray(answer) ? JSON.stringify(answer) : null
        ]);
        
        savedResponses.push({ questionKey, answer });
      }
    }
    
    // Obtener datos de la encuesta para la recompensa
    const surveyResult = await client.query(`
      SELECT survey_key, reward_amount FROM surveys WHERE id = $1
    `, [surveyId]);
    
    if (surveyResult.rows.length > 0) {
      const { survey_key, reward_amount } = surveyResult.rows[0];
      
      // Marcar encuesta como completada
      await client.query(`
        INSERT INTO user_completed_surveys (user_id, survey_id, reward_paid)
        VALUES ($1, $2, true)
      `, [userId, surveyId]);
      
      // Agregar transacción de recompensa
      await client.query(`
        INSERT INTO transactions (user_id, transaction_type, amount, description, reference_id, status)
        VALUES ($1, 'survey_reward', $2, $3, $4, 'completed')
      `, [
        userId, 
        reward_amount, 
        `Recompensa por completar encuesta: ${survey_key}`,
        survey_key
      ]);
      
      // Actualizar balance del usuario
      await client.query(`
        UPDATE users SET balance = (
          SELECT COALESCE(SUM(
            CASE 
              WHEN transaction_type IN ('survey_reward', 'referral_bonus') THEN amount
              WHEN transaction_type IN ('withdrawal_request', 'withdrawal_completed') THEN -amount
              ELSE 0
            END
          ), 0) FROM transactions WHERE user_id = $1 AND status = 'completed'
        ) WHERE id = $1
      `, [userId]);
      
      // Log de actividad
      await client.query(`
        INSERT INTO activity_logs (user_id, activity_type, description, ip_address, user_agent, metadata)
        VALUES ($1, 'survey_completed', $2, $3, $4, $5)
      `, [
        userId,
        `Completó encuesta: ${survey_key}`,
        userIp,
        userAgent,
        JSON.stringify({ surveyId, responses: savedResponses })
      ]);
    }
    
    await client.query('COMMIT');
    
    console.log('Survey completed successfully:', { userId, surveyId, responsesCount: savedResponses.length });
    
    res.json({ 
      success: true, 
      message: 'Encuesta enviada correctamente',
      userId: userId,
      responsesCount: savedResponses.length
    });
    
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('Survey submission error:', error);
    res.status(400).json({ error: error.message });
  } finally {
    client.release();
  }
});

// API para solicitar retiro
app.post('/api/withdrawals', async (req, res) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    
    const { userId, amount, paypalEmail } = req.body;
    const userIp = req.headers['x-forwarded-for'] || req.connection.remoteAddress || req.ip;
    
    // Verificar balance del usuario
    const balanceResult = await client.query(`
      SELECT balance FROM users WHERE id = $1
    `, [userId]);
    
    if (balanceResult.rows.length === 0) {
      throw new Error('Usuario no encontrado');
    }
    
    const currentBalance = parseFloat(balanceResult.rows[0].balance);
    
    if (currentBalance < amount) {
      throw new Error('Saldo insuficiente');
    }
    
    if (amount < 5) {
      throw new Error('El monto mínimo de retiro es 5 EUR');
    }
    
    // Crear solicitud de retiro
    await client.query(`
      INSERT INTO withdrawal_requests (user_id, amount, paypal_email, status)
      VALUES ($1, $2, $3, 'pending')
    `, [userId, amount, paypalEmail]);
    
    // Registrar transacción pendiente
    await client.query(`
      INSERT INTO transactions (user_id, transaction_type, amount, description, paypal_email, status)
      VALUES ($1, 'withdrawal_request', $2, 'Solicitud de retiro vía PayPal', $3, 'pending')
    `, [userId, amount, paypalEmail]);
    
    // Log de actividad
    await client.query(`
      INSERT INTO activity_logs (user_id, activity_type, description, ip_address, metadata)
      VALUES ($1, 'withdrawal_requested', $2, $3, $4)
    `, [
      userId,
      `Solicitó retiro de ${amount} EUR`,
      userIp,
      JSON.stringify({ amount, paypalEmail })
    ]);
    
    await client.query('COMMIT');
    
    console.log('Withdrawal requested:', { userId, amount, paypalEmail });
    
    res.json({ 
      success: true, 
      message: 'Solicitud de retiro enviada. Procesaremos tu pago en 24-48 horas.'
    });
    
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('Withdrawal error:', error);
    res.status(400).json({ error: error.message });
  } finally {
    client.release();
  }
});

// API para estadísticas de admin
app.get('/api/admin/stats', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM admin_stats');
    res.json(result.rows[0]);
  } catch (error) {
    console.error('Error getting admin stats:', error);
    res.status(500).json({ error: error.message });
  }
});

// API para ver todas las respuestas (admin)
app.get('/api/admin/responses', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT 
        u.email,
        u.ip_address,
        s.title as survey_title,
        sq.question_text,
        usr.answer_text,
        usr.answer_options,
        usr.completed_at
      FROM user_survey_responses usr
      JOIN users u ON usr.user_id = u.id
      JOIN surveys s ON usr.survey_id = s.id
      JOIN survey_questions sq ON usr.question_id = sq.id
      ORDER BY usr.completed_at DESC
    `);
    res.json(result.rows);
  } catch (error) {
    console.error('Error getting responses:', error);
    res.status(500).json({ error: error.message });
  }
});

// Root route - provide a fallback response if index.html doesn't exist
app.get('/', (req, res) => {
  const indexPath = path.join(__dirname, 'public', 'index.html');
  
  // Check if index.html exists
  if (fs.existsSync(indexPath)) {
    res.sendFile(indexPath);
  } else {
    // Fallback response if index.html doesn't exist
    res.status(200).send(`
      <!DOCTYPE html>
      <html>
      <head>
        <title>Ángeles Sin Alas - Plataforma de Encuestas</title>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body>
        <h1>Ángeles Sin Alas - Plataforma de Encuestas</h1>
        <p>La aplicación está funcionando correctamente.</p>
        <p>API Health Check: <a href="/api/health">/api/health</a></p>
        <p>Encuestas disponibles: <a href="/api/surveys">/api/surveys</a></p>
      </body>
      </html>
    `);
  }
});

// Catch-all route for SPA (if needed)
app.get('*', (req, res) => {
  const indexPath = path.join(__dirname, 'public', 'index.html');
  
  if (fs.existsSync(indexPath)) {
    res.sendFile(indexPath);
  } else {
    res.status(404).json({ error: 'Page not found' });
  }
});

// Inicializar base de datos en el primer arranque
async function initializeDatabase() {
  try {
    console.log('Verificando estado de la base de datos...');
    
    const result = await pool.query(`
      SELECT EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name = 'users'
      );
    `);
    
    if (!result.rows[0].exists) {
      console.log('Inicializando base de datos...');
      
      // Leer y ejecutar el schema SQL
      const schemaPath = path.join(__dirname, 'schema.sql');
      if (fs.existsSync(schemaPath)) {
        const schemaSQL = fs.readFileSync(schemaPath, 'utf8');
        await pool.query(schemaSQL);
        console.log('Base de datos inicializada correctamente');
      } else {
        console.error('Archivo schema.sql no encontrado');
      }
    } else {
      console.log('Base de datos ya inicializada');
    }
  } catch (error) {
    console.error('Error inicializando base de datos:', error);
  }
}

// Manejar errores no capturados
process.on('unhandledRejection', (err) => {
  console.error('Unhandled Promise rejection:', err);
});

process.on('uncaughtException', (err) => {
  console.error('Uncaught Exception:', err);
  process.exit(1);
});

// Cerrar conexiones de BD al salir
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, closing database connections...');
  await pool.end();
  process.exit(0);
});

// Start server with proper error handling
app.listen(port, '0.0.0.0', async () => {
  console.log(`Servidor corriendo en puerto ${port}`);
  console.log(`Entorno: ${process.env.NODE_ENV || 'development'}`);
  try {
    await initializeDatabase();
  } catch (error) {
    console.error('Failed to initialize database:', error);
  }
});