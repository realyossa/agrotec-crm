// Configuração do console — UMA por cliente/deploy.
// A chave "anon" é pública por desenho (vai para o navegador de quem entra);
// o que protege os dados é o login + RLS no banco. A chave service_role
// NUNCA entra aqui.
window.CONSOLE_CONFIG = {
  cliente: 'Agrotec',
  nome: 'Agrotec Imobiliária',
  site: 'https://agrotecimobiliarianoagro.com.br',
  registroEventos: 'https://agrotecimobiliarianoagro.com.br/eventos.json',
  supabaseUrl: 'https://ectavvqeyktcditsbvjd.supabase.co',
  supabaseAnonKey: 'sb_publishable_7M0BnX4WkBKUbS3UM_soyw_28kkuaDR', // Settings > API Keys > Publishable (pública por desenho)
  // Senha única: o console entra sempre com este usuário do Supabase Auth
  // (criado em Authentication > Users). A tela pede só a senha. Se um dia
  // quiser um login por pessoa, deixe vazio e crie os usuários.
  loginEmail: 'painel@agrotecimobiliarianoagro.com.br',
  temaPadrao: 'noite'                              // 'noite' ou 'campo'
};
