{
  type token = EOF | P | CNF | ZERO | LIT of int
}

let number = ['1' - '9'] ['0' - '9']*

rule token = parse
  | eof                     { EOF }
  | "c"                     { comment lexbuf }
  | [' ' '\t' '\r']         { token lexbuf }
  | 'p'                     { P }
  | "cnf"                   { CNF }
  | '\n'                    { Lexing.new_line lexbuf; token lexbuf }
  | '0'                     { ZERO }
  | '-'? number             { LIT (int_of_string (Lexing.lexeme lexbuf)) }
  | _                       { Error.errorf "dimacs.lexer: unexpected char `%s`" (Lexing.lexeme lexbuf) }

and comment = parse
  | '\n'                    { Lexing.new_line lexbuf; token lexbuf }
  | [^'\n']                 { comment lexbuf }
