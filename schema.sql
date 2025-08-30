-- Extensiones necesarias
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
    options JSONB,
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
    answer_options JSONB,
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, survey_id, question_id)
);

-- Tabla de encuestas completadas
CREATE TABLE user_completed_surveys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    survey_id INTEGER REFERENCES surveys(id) ON DELETE CASCADE,
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    reward_paid BOOLEAN DEFAULT FALSE,
    UNIQUE(user_id, survey_id)
);

-- Tabla de transacciones
CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('survey_reward', 'referral_bonus', 'withdrawal_request', 'withdrawal_completed')),
    amount DECIMAL(10,2) NOT NULL,
    description TEXT,
    reference_id VARCHAR(100),
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

-- Tabla de retiros
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

-- Tabla de logs de actividad
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

-- Configuración del sistema
CREATE TABLE system_config (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_referral_code ON users(referral_code);
CREATE INDEX idx_users_referred_by ON users(referred_by);
CREATE INDEX idx_user_survey_responses_user_survey ON user_survey_responses(user_id, survey_id);
CREATE INDEX idx_transactions_user_id ON transactions(user_id);
CREATE INDEX idx_transactions_type_status ON transactions(transaction_type, status);
CREATE INDEX idx_referrals_referrer_id ON referrals(referrer_id);
CREATE INDEX idx_withdrawal_requests_status ON withdrawal_requests(status);
CREATE INDEX idx_activity_logs_user_activity ON activity_logs(user_id, activity_type);

-- Función balance corregida
CREATE OR REPLACE FUNCTION get_user_balance(user_uuid UUID)
RETURNS DECIMAL(10,2) AS $$
DECLARE
    total DECIMAL(10,2);
BEGIN
    SELECT 
        COALESCE(SUM(
            CASE 
                WHEN transaction_type IN ('survey_reward', 'referral_bonus') THEN amount
                WHEN transaction_type IN ('withdrawal_request','withdrawal_completed') THEN -amount
                ELSE 0
            END
        ), 0)
    INTO total
    FROM transactions
    WHERE user_id = user_uuid;

    RETURN total;
END;
$$ LANGUAGE plpgsql;

-- Vista para dashboard de usuario
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

-- Habilitar RLS
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_survey_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_completed_surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_logs ENABLE ROW LEVEL SECURITY;

-- Políticas
CREATE POLICY user_is_self ON users
FOR SELECT USING (id = auth.uid());

CREATE POLICY user_own_transactions ON transactions
FOR SELECT USING (user_id = auth.uid());

CREATE POLICY user_own_completed_surveys ON user_completed_surveys
FOR SELECT USING (user_id = auth.uid());

CREATE POLICY user_own_responses ON user_survey_responses
FOR SELECT USING (user_id = auth.uid());

CREATE POLICY user_own_referrals ON referrals
FOR SELECT USING (referrer_id = auth.uid() OR referred_user_id = auth.uid());

-- Usuario administrador por defecto
INSERT INTO users (email, password_hash, referral_code, balance) 
VALUES ('admin@angelessinalas.com', crypt('admin123', gen_salt('bf')), 'ADMIN001', 0.00);
