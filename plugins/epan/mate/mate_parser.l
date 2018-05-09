%top {
/* Include this before everything else, for various large-file definitions */
#include "config.h"
/* Include this before everything else, as it declares functions used here. */
#include "mate.h"
}

/*
 * We want a reentrant scanner.
 */
%option reentrant

/*
 * We don't use input, so don't generate code for it.
 */
%option noinput

/*
 * We don't use unput, so don't generate code for it.
 */
%option nounput

/*
 * We don't read interactively from the terminal.
 */
%option never-interactive

/*
 * We want to stop processing when we get to the end of the input.
 */
%option noyywrap

/*
 * The type for the state we keep for a scanner.
 */
%option extra-type="Mate_scanner_state_t *"

/*
 * We have to override the memory allocators so that we don't get
 * "unused argument" warnings from the yyscanner argument (which
 * we don't use, as we have a global memory allocator).
 *
 * We provide, as macros, our own versions of the routines generated by Flex,
 * which just call malloc()/realloc()/free() (as the Flex versions do),
 * discarding the extra argument.
 */
%option noyyalloc
%option noyyrealloc
%option noyyfree

/*
 * Prefix scanner routines with "Mate_" rather than "yy", so this scanner
 * can coexist with other scanners.
 */
%option prefix="Mate_"

%{

	/* mate_parser.l
	* lexical analyzer for MATE configuration files
	*
	* Copyright 2004, Luis E. Garcia Ontanon <luis@ontanon.org>
	*
	* Wireshark - Network traffic analyzer
	* By Gerald Combs <gerald@wireshark.org>
	* Copyright 1998 Gerald Combs
	*
	* This program is free software; you can redistribute it and/or
	* modify it under the terms of the GNU General Public License
	* as published by the Free Software Foundation; either version 2
	* of the License, or (at your option) any later version.
	*
	* This program is distributed in the hope that it will be useful,
	* but WITHOUT ANY WARRANTY; without even the implied warranty of
	* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	* GNU General Public License for more details.
	*
	* You should have received a copy of the GNU General Public License
	* along with this program; if not, write to the Free Software
	* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
	*/

#include "mate_grammar.h"

#include <wsutil/file_util.h>

/*
 * Disable diagnostics in the code generated by Flex.
 */
DIAG_OFF_FLEX

	void MateParseTrace(FILE*,char*);

#define MAX_INCLUDE_DEPTH 10
typedef struct {
	mate_config* mc;

	mate_config_frame* current_frame;

	void* pParser;

	YY_BUFFER_STATE include_stack[MAX_INCLUDE_DEPTH];
	int include_stack_ptr;
} Mate_scanner_state_t;

#define MATE_PARSE(token_type) MateParser(yyextra->pParser, (token_type), g_strdup(yytext), yyextra->mc);

/*
 * Flex (v 2.5.35) uses this symbol to "exclude" unistd.h
 */
#ifdef _WIN32
#define YY_NO_UNISTD_H
#endif

static void free_config_frame(mate_config_frame *frame) {
	g_free(frame->filename);
	g_free(frame);
}

#define YY_USER_INIT BEGIN OUTSIDE;

/*
 * Sleazy hack to suppress compiler warnings in yy_fatal_error().
 */
#define YY_EXIT_FAILURE ((void)yyscanner, 2)

/*
 * Macros for the allocators, to discard the extra argument.
 */
#define Mate_alloc(size, yyscanner)		(void *)malloc(size)
#define Mate_realloc(ptr, size, yyscanner)	(void *)realloc((char *)(ptr), (size))
#define Mate_free(ptr, yyscanner)		free((char *)ptr)

%}

pdu_kw				Pdu
gop_kw				Gop
gog_kw				Gog
transform_kw		Transform
match_kw			Match
always_kw			Always
strict_kw			Strict
every_kw			Every
loose_kw			Loose
replace_kw			Replace
insert_kw			Insert
gop_tree_kw			GopTree
member_kw			Member
on_kw				On
start_kw			Start
stop_kw				Stop
extra_kw			Extra
show_tree_kw		ShowTree
show_times_kw		ShowTimes
expiration_kw		Expiration
idle_timeout_kw		IdleTimeout
lifetime_kw			Lifetime
no_tree_kw			NoTree
pdu_tree_kw			PduTree
frame_tree_kw		FrameTree
basic_tree_kw		BasicTree
true_kw				[Tt][Rr][Uu][Ee]
false_kw			[Ff][Aa][Ll][Ss][Ee]
proto_kw			Proto
payload_kw			Payload
transport_kw		Transport
criteria_kw			Criteria
accept_kw			Accept
reject_kw			Reject
extract_kw			Extract
from_kw				From
drop_unassigned_kw  DropUnassigned
discard_pdu_data_kw DiscardPduData
last_pdu_kw			LastPdu
done_kw				Done
filename_kw			Filename
debug_kw			Debug
level_kw			Level
default_kw			Default


open_parens			"("
close_parens		")"
open_brace			"{"
close_brace			"}"
comma				","
semicolon			";"
slash				"/"
pipe				"|"

integer				[0-9]+
floating			([0-9]+\.[0-9]+)
doted_ip			[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?
colonized			[0-9A-Fa-f:]*[:][0-9A-Fa-f:]*

name				[a-z][-\.a-zA-Z0-9_]*
avp_operator		[$^~=<>!]
quote				["]
not_quoted			[^"]*

include			"#include"
filename		[-A-Za-z0-9_/.]+

whitespace		[[:blank:]\r]+
newline			\n

comment			"//"[^\n]*\n

blk_cmnt_start  "/*"
cmnt_char		.
blk_cmnt_stop  "*/"

%START OUTSIDE QUOTED INCLUDING COMMENT
%%

{newline}				yyextra->current_frame->linenum++;
{whitespace}				;

<OUTSIDE>{include}			BEGIN INCLUDING;

<INCLUDING>{filename}			{
	if ( yyextra->include_stack_ptr >= MAX_INCLUDE_DEPTH )
		g_error("dtd_preparse: include files nested too deeply");

	yyextra->include_stack[yyextra->include_stack_ptr++] = YY_CURRENT_BUFFER;
	yyin = ws_fopen( yytext, "r" );

	if (!yyin) {
		Mate__delete_buffer(YY_CURRENT_BUFFER, yyscanner);

		/* coverity[negative_sink] */
		Mate__switch_to_buffer(yyextra->include_stack[--yyextra->include_stack_ptr], yyscanner);

		if (errno)
			g_string_append_printf(yyextra->mc->config_error, "Mate parser: Could not open file: '%s': %s", yytext, g_strerror(errno) );

	} else {

		yyextra->current_frame = (mate_config_frame *)g_malloc(sizeof(mate_config_frame));
		yyextra->current_frame->filename = g_strdup(yytext);
		yyextra->current_frame->linenum = 1;

		g_ptr_array_add(yyextra->mc->config_stack,yyextra->current_frame);

		Mate__switch_to_buffer(Mate__create_buffer(yyin, YY_BUF_SIZE, yyscanner), yyscanner);
	}

	BEGIN OUTSIDE;
}

<<EOF>>	{
	/* coverity[check_after_sink] */
	if ( --yyextra->include_stack_ptr < 0 ) {
		yyterminate();
	} else {
		Mate__delete_buffer(YY_CURRENT_BUFFER, yyscanner);
		Mate__switch_to_buffer(yyextra->include_stack[yyextra->include_stack_ptr], yyscanner);

		free_config_frame(yyextra->current_frame);
		yyextra->current_frame = (mate_config_frame *)g_ptr_array_remove_index(yyextra->mc->config_stack,yyextra->mc->config_stack->len-1);
	}
}

<OUTSIDE>{comment}			;

<OUTSIDE>{blk_cmnt_start}		BEGIN COMMENT;
<COMMENT>{cmnt_char}			;
<COMMENT>{blk_cmnt_stop}		BEGIN OUTSIDE;

<OUTSIDE>{pdu_kw}			MATE_PARSE(TOKEN_PDU_KW);
<OUTSIDE>{gop_kw}			MATE_PARSE(TOKEN_GOP_KW);
<OUTSIDE>{gog_kw}			MATE_PARSE(TOKEN_GOG_KW);
<OUTSIDE>{transform_kw}			MATE_PARSE(TOKEN_TRANSFORM_KW);
<OUTSIDE>{match_kw}			MATE_PARSE(TOKEN_MATCH_KW);
<OUTSIDE>{strict_kw}			MATE_PARSE(TOKEN_STRICT_KW);
<OUTSIDE>{every_kw}			MATE_PARSE(TOKEN_EVERY_KW);
<OUTSIDE>{loose_kw}			MATE_PARSE(TOKEN_LOOSE_KW);
<OUTSIDE>{replace_kw}			MATE_PARSE(TOKEN_REPLACE_KW);
<OUTSIDE>{insert_kw}			MATE_PARSE(TOKEN_INSERT_KW);
<OUTSIDE>{gop_tree_kw}			MATE_PARSE(TOKEN_GOP_TREE_KW);
<OUTSIDE>{member_kw}			MATE_PARSE(TOKEN_MEMBER_KW);
<OUTSIDE>{on_kw}			MATE_PARSE(TOKEN_ON_KW);
<OUTSIDE>{start_kw}			MATE_PARSE(TOKEN_START_KW);
<OUTSIDE>{stop_kw}			MATE_PARSE(TOKEN_STOP_KW);
<OUTSIDE>{extra_kw}			MATE_PARSE(TOKEN_EXTRA_KW);
<OUTSIDE>{show_tree_kw}			MATE_PARSE(TOKEN_SHOW_TREE_KW);
<OUTSIDE>{show_times_kw}		MATE_PARSE(TOKEN_SHOW_TIMES_KW);
<OUTSIDE>{expiration_kw}		MATE_PARSE(TOKEN_EXPIRATION_KW);
<OUTSIDE>{idle_timeout_kw}		MATE_PARSE(TOKEN_IDLE_TIMEOUT_KW);
<OUTSIDE>{lifetime_kw}			MATE_PARSE(TOKEN_LIFETIME_KW);
<OUTSIDE>{no_tree_kw}			MATE_PARSE(TOKEN_NO_TREE_KW);
<OUTSIDE>{pdu_tree_kw}			MATE_PARSE(TOKEN_PDU_TREE_KW);
<OUTSIDE>{frame_tree_kw}		MATE_PARSE(TOKEN_FRAME_TREE_KW);
<OUTSIDE>{basic_tree_kw}		MATE_PARSE(TOKEN_BASIC_TREE_KW);
<OUTSIDE>{true_kw}			MATE_PARSE(TOKEN_TRUE_KW);
<OUTSIDE>{false_kw}			MATE_PARSE(TOKEN_FALSE_KW);
<OUTSIDE>{proto_kw}			MATE_PARSE(TOKEN_PROTO_KW);
<OUTSIDE>{payload_kw}			MATE_PARSE(TOKEN_PAYLOAD_KW);
<OUTSIDE>{transport_kw}			MATE_PARSE(TOKEN_TRANSPORT_KW);
<OUTSIDE>{criteria_kw}			MATE_PARSE(TOKEN_CRITERIA_KW);
<OUTSIDE>{accept_kw}			MATE_PARSE(TOKEN_ACCEPT_KW);
<OUTSIDE>{reject_kw}			MATE_PARSE(TOKEN_REJECT_KW);
<OUTSIDE>{extract_kw}			MATE_PARSE(TOKEN_EXTRACT_KW);
<OUTSIDE>{from_kw}			MATE_PARSE(TOKEN_FROM_KW);
<OUTSIDE>{drop_unassigned_kw}		MATE_PARSE(TOKEN_DROP_UNASSIGNED_KW);
<OUTSIDE>{discard_pdu_data_kw}		MATE_PARSE(TOKEN_DISCARD_PDU_DATA_KW);
<OUTSIDE>{last_pdu_kw}			MATE_PARSE(TOKEN_LAST_PDU_KW);
<OUTSIDE>{done_kw}			MATE_PARSE(TOKEN_DONE_KW);
<OUTSIDE>{filename_kw}			MATE_PARSE(TOKEN_FILENAME_KW);
<OUTSIDE>{debug_kw}			MATE_PARSE(TOKEN_DEBUG_KW);
<OUTSIDE>{level_kw}			MATE_PARSE(TOKEN_LEVEL_KW);
<OUTSIDE>{default_kw}			MATE_PARSE(TOKEN_DEFAULT_KW);

<OUTSIDE>{open_parens}			MATE_PARSE(TOKEN_OPEN_PARENS);
<OUTSIDE>{close_parens}			MATE_PARSE(TOKEN_CLOSE_PARENS);
<OUTSIDE>{open_brace}			MATE_PARSE(TOKEN_OPEN_BRACE);
<OUTSIDE>{close_brace}			MATE_PARSE(TOKEN_CLOSE_BRACE);
<OUTSIDE>{comma}			MATE_PARSE(TOKEN_COMMA);
<OUTSIDE>{semicolon}			MATE_PARSE(TOKEN_SEMICOLON);
<OUTSIDE>{slash}			MATE_PARSE(TOKEN_SLASH);
<OUTSIDE>{pipe}				MATE_PARSE(TOKEN_PIPE);

<OUTSIDE>{integer}			MATE_PARSE(TOKEN_INTEGER);
<OUTSIDE>{floating}			MATE_PARSE(TOKEN_FLOATING);
<OUTSIDE>{doted_ip}			MATE_PARSE(TOKEN_DOTED_IP);
<OUTSIDE>{colonized}			MATE_PARSE(TOKEN_COLONIZED);
<OUTSIDE>{name}				MATE_PARSE(TOKEN_NAME);
<OUTSIDE>{avp_operator}			MATE_PARSE(TOKEN_AVP_OPERATOR);


<OUTSIDE>{quote}			BEGIN QUOTED;
<QUOTED>{not_quoted}			MATE_PARSE(TOKEN_QUOTED);
<QUOTED>{quote}				BEGIN OUTSIDE;

%%

/*
 * Turn diagnostics back on, so we check the code that we've written.
 */
DIAG_ON_FLEX

static void ptr_array_free(gpointer data, gpointer user_data _U_)
{
	free_config_frame((mate_config_frame *)data);
}

extern gboolean mate_load_config(const gchar* filename, mate_config* mc) {
	FILE *in;
	yyscan_t scanner;
	Mate_scanner_state_t state;
	volatile gboolean status = TRUE;

	in = ws_fopen(filename,"r");

	if (!in) {
		g_string_append_printf(mc->config_error,"Mate parser: Could not open file: '%s', error: %s", filename, g_strerror(errno) );
		return FALSE;
	}

	if (Mate_lex_init(&scanner) != 0) {
		g_string_append_printf(mc->config_error, "Mate parse: Could not initialize scanner: %s", g_strerror(errno));
		fclose(in);
		return FALSE;
	}

	Mate_set_in(in, scanner);

	mc->config_stack = g_ptr_array_new();

	state.mc = mc;

	state.current_frame = (mate_config_frame *)g_malloc(sizeof(mate_config_frame));
	state.current_frame->filename = g_strdup(filename);
	state.current_frame->linenum = 1;

	g_ptr_array_add(mc->config_stack,state.current_frame);

	state.pParser = MateParserAlloc(g_malloc);

	state.include_stack_ptr = 0;

	/* Associate the state with the scanner */
	Mate_set_extra(&state, scanner);

	/* MateParserTrace(stdout,""); */

	TRY {
		Mate_lex(scanner);

		/* Inform parser that end of input has reached. */
		MateParser(state.pParser, 0, NULL, mc);

		MateParserFree(state.pParser, g_free);
	} CATCH(MateConfigError) {
		status = FALSE;
	} CATCH_ALL {
		status = FALSE;
		g_string_append_printf(mc->config_error,"An unexpected error occurred");
	}
	ENDTRY;

	Mate_lex_destroy(scanner);
	fclose(in);

	g_ptr_array_foreach(mc->config_stack, ptr_array_free, NULL);
	g_ptr_array_free(mc->config_stack, FALSE);

	return status;
}