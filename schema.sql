-- Ángeles Sin Alas - Database Schema for PostgreSQL
-- Para usar en Railway, guarda este archivo como schema.sql en tu repositorio

-- Crear extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Tabla de usuarios
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255),
    balance DECIMAL(10,2) DEFAULT 0.00,
    referral_code VARCHAR(20) UNIQUE NOT NULL,
    referred_by VARCHAR(20),
    total_referrals INTEGER DEFAULT 0,
    ip_address INET,
    user_agent TEXT,
    email_verified BOOLEAN DEFAULT FALSE,
    verification_token VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_login TIMESTAMP WITH TIME ZONE
);

-- Tabla de encuestas disponibles
CREATE TABLE surveys (
    id SERIAL PRIMARY KEY,
    survey_key VARCHAR(50) UNIQUE NOT NULL,
    title VARCHAR(200) NOT NULL,
    description TEXT,
    reward_amount DECIMAL(10,2) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabla de preguntas de encuestas
CREATE TABLE survey_questions (
    id SERIAL PRIMARY KEY,
    survey_id INTEGER REFERENCES surveys(id) ON DELETE CASCADE,
    question_key VARCHAR(50) NOT NULL,
    question_text TEXT NOT NULL,
    question_type VARCHAR(20) NOT NULL CHECK (question_type IN ('radio', 'checkbox', 'text', 'textarea')),
    options JSONB, -- Para guardar las opciones de respuesta
    is_required BOOLEAN DEFAULT TRUE,
    order_index INTEGER DEFAULT 0
);

-- Tabla de respuestas de usuarios
CREATE TABLE user_survey_responses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    survey_id INTEGER REFERENCES surveys(id) ON DELETE CASCADE,
    question_id INTEGER REFERENCES survey_questions(id) ON DELETE CASCADE,
    answer_text TEXT,
    answer_options JSONB, -- Para respuestas múltiples
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, survey_id, question_id)
);

-- Tabla de encuestas completadas por usuario
CREATE TABLE user_completed_surveys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    survey_id INTEGER REFERENCES surveys(id) ON DELETE CASCADE,
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    reward_paid BOOLEAN DEFAULT FALSE,
    UNIQUE(user_id, survey_id)
);

-- Tabla de transacciones/movimientos de dinero
CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('survey_reward', 'referral_bonus', 'withdrawal_request', 'withdrawal_completed')),
    amount DECIMAL(10,2) NOT NULL,
    description TEXT,
    reference_id VARCHAR(100), -- ID de encuesta, referido, etc.
    status VARCHAR(20) DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'failed', 'cancelled')),
    paypal_email VARCHAR(255),
    paypal_transaction_id VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    processed_at TIMESTAMP WITH TIME ZONE
);

-- Tabla de referidos
CREATE TABLE referrals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    referrer_id UUID REFERENCES users(id) ON DELETE CASCADE,
    referred_user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    referral_code VARCHAR(20) NOT NULL,
    bonus_paid BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(referrer_id, referred_user_id)
);

-- Tabla de retiros solicitados
CREATE TABLE withdrawal_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    amount DECIMAL(10,2) NOT NULL,
    paypal_email VARCHAR(255) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    admin_notes TEXT,
    requested_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    processed_at TIMESTAMP WITH TIME ZONE,
    paypal_transaction_id VARCHAR(100)
);

-- Tabla de logs de actividad (para auditoría)
CREATE TABLE activity_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    activity_type VARCHAR(50) NOT NULL,
    description TEXT,
    ip_address INET,
    user_agent TEXT,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabla de configuración del sistema
CREATE TABLE system_config (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para mejorar el rendimiento
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_referral_code ON users(referral_code);
CREATE INDEX idx_users_referred_by ON users(referred_by);
CREATE INDEX idx_user_survey_responses_user_survey ON user_survey_responses(user_id, survey_id);
CREATE INDEX idx_transactions_user_id ON transactions(user_id);
CREATE INDEX idx_transactions_type_status ON transactions(transaction_type, status);
CREATE INDEX idx_referrals_referrer_id ON referrals(referrer_id);
CREATE INDEX idx_withdrawal_requests_status ON withdrawal_requests(status);
CREATE INDEX idx_activity_logs_user_activity ON activity_logs(user_id, activity_type);

-- Función para generar códigos de referido únicos
CREATE OR REPLACE FUNCTION generate_unique_referral_code() RETURNS VARCHAR(20) AS $$
DECLARE
    new_code VARCHAR(20);
    code_exists BOOLEAN;
BEGIN
    LOOP
        -- Generar un código de 8 caracteres alfanuméricos
        new_code := upper(substr(md5(random()::text), 1, 8));
        
        -- Verificar si ya existe
        SELECT EXISTS(SELECT 1 FROM users WHERE referral_code = new_code) INTO code_exists;
        
        -- Si no existe, usar este código
        IF NOT code_exists THEN
            EXIT;
        END IF;
    END LOOP;
    
    RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Trigger para generar código de referido automáticamente
CREATE OR REPLACE FUNCTION set_referral_code() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.referral_code IS NULL OR NEW.referral_code = '' THEN
        NEW.referral_code := generate_unique_referral_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_referral_code
    BEFORE INSERT ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_referral_code();

-- Trigger para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Insertar encuestas iniciales
INSERT INTO surveys (survey_key, title, description, reward_amount) VALUES
('main_survey', 'Encuesta Principal', 'Conoce más sobre nuestra asociación y cuidados paliativos', 5.00),
('communication', 'Comunicación Digital', 'Preferencias de comunicación digital', 1.00),
('donations', 'Donaciones Digitales', 'Experiencia con plataformas de donación online', 1.00),
('socioeconomic', 'Encuesta Socioeconómica', 'Información general sobre tu situación (opcional y anónima)', 1.00),
('volunteering', 'Voluntariado', 'Interés en participar como voluntario presencial', 1.00),
('feedback', 'Feedback de la Plataforma', 'Ayúdanos a mejorar esta experiencia', 1.00);

-- Insertar preguntas de la encuesta principal
INSERT INTO survey_questions (survey_id, question_key, question_text, question_type, options, order_index) VALUES
(1, 'q1', '¿Conocías antes la existencia de asociaciones como Ángeles Sin Alas?', 'radio', '["Sí", "No", "He oído hablar, pero no conozco en detalle"]', 1),
(1, 'q2', '¿Qué tan importante consideras que es apoyar a niños en cuidados paliativos y a sus familias?', 'radio', '["Muy importante", "Importante", "Poco importante", "No lo considero necesario"]', 2),
(1, 'q3', '¿Has colaborado alguna vez con una ONG o asociación solidaria?', 'radio', '["Sí, de forma económica", "Sí, como voluntario/a", "Sí, donando material o servicios", "No, nunca"]', 3),
(1, 'q4', 'Si tuvieras la oportunidad, ¿cómo preferirías colaborar con una asociación como Ángeles Sin Alas? (Respuesta múltiple)', 'checkbox', '["Donando dinero", "Siendo voluntario/a", "Difundiendo en redes sociales", "Donando material o recursos", "No me interesa participar"]', 4),
(1, 'q5', '¿Qué tipo de apoyo crees que necesitan más las familias con niños en cuidados paliativos?', 'radio', '["Apoyo económico", "Apoyo emocional / psicológico", "Material ortoprotésico (sillas, camas, etc.)", "Actividades y experiencias para los niños", "Todos los anteriores"]', 5),
(1, 'q6', '¿En qué parte del mundo vives actualmente?', 'text', 'null', 6),
(1, 'q7', '¿Qué edad tienes?', 'radio', '["Menos de 18 años", "18 – 25 años", "26 – 40 años", "41 – 60 años", "Más de 60 años"]', 7),
(1, 'q8', '¿Con qué frecuencia donas a organizaciones solidarias?', 'radio', '["Regularmente (mensual o anual)", "Ocasionalmente (eventos, campañas puntuales)", "Muy rara vez", "Nunca"]', 8),
(1, 'q9', '¿Qué te motivaría más a colaborar con una causa como esta?', 'radio', '["Conocer testimonios reales de familias", "Ver transparencia en el uso de fondos", "Que me lo recomiende alguien cercano", "Que se me facilite un medio rápido de colaborar", "Otro (especificar)"]', 9),
(1, 'q10', '¿Quieres recibir información sobre cómo colaborar con Ángeles Sin Alas?', 'radio', '["Sí, por correo electrónico", "Sí, por redes sociales", "No, gracias"]', 10);

-- Insertar preguntas de encuestas adicionales
INSERT INTO survey_questions (survey_id, question_key, question_text, question_type, options, order_index) VALUES
-- Comunicación Digital
(2, 'communication_q1', '¿Cómo prefieres recibir información sobre causas solidarias?', 'radio', '["Email", "SMS", "Redes sociales", "No deseo recibir"]', 1),

-- Donaciones Digitales  
(3, 'donations_q1', '¿Has utilizado plataformas digitales para hacer donaciones antes?', 'radio', '["Sí, frecuentemente", "Ocasionalmente", "Nunca", "No confío en plataformas digitales"]', 1),

-- Socioeconómica
(4, 'socioeconomic_q1', '¿Cuál es tu nivel de ingresos aproximado?', 'radio', '["Prefiero no decir", "Bajo", "Medio", "Alto"]', 1),

-- Voluntariado
(5, 'volunteering_q1', '¿Estarías interesado/a en participar como voluntario presencial en Baleares?', 'radio', '["Sí, definitivamente", "Tal vez", "No, pero sí online", "No me interesa"]', 1),

-- Feedback
(6, 'feedback_q1', '¿Cómo valorarías esta plataforma de encuestas?', 'radio', '["Muy útil", "Útil", "Regular", "Poco útil", "Sugiero mejoras"]', 1);

-- Insertar configuración inicial del sistema
INSERT INTO system_config (key, value, description) VALUES
('site_name', 'Ángeles Sin Alas - Plataforma de Encuestas', 'Nombre del sitio web'),
('min_withdrawal_amount', '5.00', 'Cantidad mínima para retirar en EUR'),
('max_withdrawal_amount', '1000.00', 'Cantidad máxima para retirar en EUR'),
('referral_bonus_threshold', '10', 'Número de referidos necesarios para bonus'),
('referral_bonus_amount', '10.00', 'Cantidad del bonus por referidos en EUR'),
('site_maintenance', 'false', 'Modo mantenimiento del sitio'),
('registration_enabled', 'true', 'Permitir nuevos registros'),
('paypal_sandbox_mode', 'true', 'Usar PayPal en modo sandbox/pruebas');

-- Funciones útiles para consultas

-- Función para obtener el balance actual de un usuario
CREATE OR REPLACE FUNCTION get_user_balance(user_uuid UUID) RETURNS DECIMAL(10,2) AS $$
DECLARE
    balance DECIMAL(10,2) := 0.00;
BEGIN
    SELECT COALESCE(
        (SELECT SUM(amount) FROM transactions 
         WHERE user_id = user_uuid 
         AND transaction_type IN ('survey_reward', 'referral_bonus')
         AND status = 'completed')
        -
        (SELECT SUM(amount) FROM transactions 
         WHERE user_id = user_uuid 
         AND transaction_type IN ('withdrawal_request', 'withdrawal_completed')
         AND status = 'completed'), 
        0.00
    ) INTO balance;
    
    RETURN balance;
END;
$$ LANGUAGE plpgsql;

-- Función para verificar si un usuario puede completar una encuesta
CREATE OR REPLACE FUNCTION can_user_complete_survey(user_uuid UUID, survey_key_param VARCHAR) RETURNS BOOLEAN AS $$
DECLARE
    already_completed BOOLEAN := FALSE;
    survey_id_param INTEGER;
BEGIN
    -- Obtener el ID de la encuesta
    SELECT id INTO survey_id_param FROM surveys WHERE survey_key = survey_key_param AND is_active = TRUE;
    
    IF survey_id_param IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- Verificar si ya completó esta encuesta
    SELECT EXISTS(
        SELECT 1 FROM user_completed_surveys 
        WHERE user_id = user_uuid AND survey_id = survey_id_param
    ) INTO already_completed;
    
    RETURN NOT already_completed;
END;
$$ LANGUAGE plpgsql;

-- Función para procesar recompensa de encuesta
CREATE OR REPLACE FUNCTION process_survey_reward(user_uuid UUID, survey_key_param VARCHAR) RETURNS BOOLEAN AS $$
DECLARE
    survey_record RECORD;
    can_complete BOOLEAN;
BEGIN
    -- Verificar si puede completar la encuesta
    SELECT can_user_complete_survey(user_uuid, survey_key_param) INTO can_complete;
    
    IF NOT can_complete THEN
        RETURN FALSE;
    END IF;
    
    -- Obtener datos de la encuesta
    SELECT id, reward_amount INTO survey_record 
    FROM surveys 
    WHERE survey_key = survey_key_param AND is_active = TRUE;
    
    IF survey_record IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- Marcar encuesta como completada
    INSERT INTO user_completed_surveys (user_id, survey_id, reward_paid)
    VALUES (user_uuid, survey_record.id, TRUE);
    
    -- Agregar transacción de recompensa
    INSERT INTO transactions (user_id, transaction_type, amount, description, reference_id, status)
    VALUES (user_uuid, 'survey_reward', survey_record.reward_amount, 
            'Recompensa por completar encuesta: ' || survey_key_param, 
            survey_key_param, 'completed');
    
    -- Actualizar balance del usuario
    UPDATE users SET balance = get_user_balance(user_uuid) WHERE id = user_uuid;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Función para procesar bonus de referidos
CREATE OR REPLACE FUNCTION check_referral_bonus(user_uuid UUID) RETURNS BOOLEAN AS $$
DECLARE
    referral_count INTEGER := 0;
    bonus_threshold INTEGER;
    bonus_amount DECIMAL(10,2);
    already_received BOOLEAN := FALSE;
BEGIN
    -- Obtener configuración de referidos
    SELECT value::INTEGER INTO bonus_threshold FROM system_config WHERE key = 'referral_bonus_threshold';
    SELECT value::DECIMAL INTO bonus_amount FROM system_config WHERE key = 'referral_bonus_amount';
    
    -- Contar referidos del usuario
    SELECT COUNT(*) INTO referral_count FROM referrals WHERE referrer_id = user_uuid;
    
    -- Verificar si ya recibió el bonus
    SELECT EXISTS(
        SELECT 1 FROM transactions 
        WHERE user_id = user_uuid 
        AND transaction_type = 'referral_bonus' 
        AND status = 'completed'
    ) INTO already_received;
    
    -- Si tiene suficientes referidos y no ha recibido el bonus
    IF referral_count >= bonus_threshold AND NOT already_received THEN
        -- Agregar transacción de bonus
        INSERT INTO transactions (user_id, transaction_type, amount, description, reference_id, status)
        VALUES (user_uuid, 'referral_bonus', bonus_amount, 
                'Bonus por alcanzar ' || bonus_threshold || ' referidos', 
                'referral_bonus_' || bonus_threshold, 'completed');
        
        -- Actualizar balance del usuario
        UPDATE users SET balance = get_user_balance(user_uuid) WHERE id = user_uuid;
        
        RETURN TRUE;
    END IF;
    
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Vista para estadísticas de administrador
CREATE OR REPLACE VIEW admin_stats AS
SELECT 
    (SELECT COUNT(*) FROM users) as total_users,
    (SELECT COUNT(*) FROM users WHERE created_at > NOW() - INTERVAL '7 days') as new_users_week,
    (SELECT COUNT(*) FROM user_completed_surveys) as total_surveys_completed,
    (SELECT COUNT(*) FROM user_completed_surveys WHERE completed_at > NOW() - INTERVAL '7 days') as surveys_completed_week,
    (SELECT COALESCE(SUM(amount), 0) FROM transactions WHERE transaction_type IN ('survey_reward', 'referral_bonus') AND status = 'completed') as total_rewards_paid,
    (SELECT COALESCE(SUM(amount), 0) FROM transactions WHERE transaction_type IN ('withdrawal_request', 'withdrawal_completed') AND status = 'completed') as total_withdrawals,
    (SELECT COUNT(*) FROM withdrawal_requests WHERE status = 'pending') as pending_withdrawals;

-- Vista para datos de usuario (para API)
CREATE OR REPLACE VIEW user_dashboard AS
SELECT 
    u.id,
    u.email,
    u.referral_code,
    get_user_balance(u.id) as current_balance,
    (SELECT COUNT(*) FROM referrals WHERE referrer_id = u.id) as total_referrals,
    (SELECT COUNT(*) FROM user_completed_surveys ucs 
     JOIN surveys s ON ucs.survey_id = s.id 
     WHERE ucs.user_id = u.id) as completed_surveys_count,
    u.created_at,
    u.last_login
FROM users u;

-- Política de seguridad: Los usuarios solo pueden ver sus propios datos
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_survey_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_completed_surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_logs ENABLE ROW LEVEL SECURITY;

-- Crear un usuario administrador de ejemplo
INSERT INTO users (email, password_hash, referral_code, balance) 
VALUES ('admin@angelessinalas.com', crypt('admin123', gen_salt('bf')), 'ADMIN001', 0.00);