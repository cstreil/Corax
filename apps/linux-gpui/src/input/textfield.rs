//! Ein Textfeld für den Spike: einzeilig und mehrzeilig.
//!
//! GPUI bringt kein fertiges Eingabefeld mit. Nötig ist ein View, der
//! `EntityInputHandler` umsetzt, und ein Element, das beim Malen
//! `window.handle_input` aufruft — damit gehen Tastatur, IME (Dead Keys,
//! Umlaute), Auswahl und Einfügen aus der Zwischenablage über den normalen
//! Plattformweg.

use std::ops::Range;

use gpui::prelude::*;
use gpui::*;

use crate::perf::TIPP_ZEIT;
use crate::theme::Theme;

pub struct TextField {
    pub text: String,
    /// Cursor als UTF-16-Index (das ist die Einheit der Plattform).
    pub cursor: usize,
    pub multiline: bool,
    pub placeholder: SharedString,
    pub label: SharedString,
    pub theme: Theme,
    focus: FocusHandle,
    /// Ein Dead Key, der auf sein Folgezeichen wartet (´ + e → é).
    pending_dead: Option<(char, std::time::Instant)>,
}

impl TextField {
    pub fn new(
        label: &str,
        multiline: bool,
        placeholder: &str,
        theme: Theme,
        cx: &mut Context<Self>,
    ) -> Self {
        TextField {
            text: String::new(),
            cursor: 0,
            multiline,
            placeholder: SharedString::from(placeholder.to_string()),
            label: SharedString::from(label.to_string()),
            theme,
            focus: cx.focus_handle(),
            pending_dead: None,
        }
    }

    pub fn focus_handle(&self) -> FocusHandle {
        self.focus.clone()
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    /// Test-Hook: Text einfügen, ohne den Plattformweg (Dead Keys, IME).
    pub fn type_text(&mut self, value: &str) {
        self.insert(value);
    }

    /// Ist das Feld derzeit Tastaturziel? Einzeltasten-Kürzel dürfen dann nicht greifen.
    pub fn is_focused(&self, window: &Window) -> bool {
        self.focus.is_focused(window)
    }

    fn byte_index(&self, utf16: usize) -> usize {
        let mut units = 0usize;
        for (byte, ch) in self.text.char_indices() {
            if units >= utf16 {
                return byte;
            }
            units += ch.len_utf16();
        }
        self.text.len()
    }

    /// Zeichen, die ein Dead Key beim Drücken allein liefert.
    const TOT: &'static str = "´`^¨~¸ˇ˘˙˚˝¯";

    /// Wartenden Dead Key einfügen, wenn kein Folgezeichen kam.
    pub fn flush_dead(&mut self, cx: &mut Context<Self>) -> bool {
        match self.pending_dead {
            Some((c, t)) if t.elapsed() > std::time::Duration::from_millis(700) => {
                self.pending_dead = None;
                self.insert_raw(&c.to_string());
                eprintln!("DEADKEY allein eingefuegt {:?}", c);
                cx.notify();
                true
            }
            _ => false,
        }
    }

    fn insert(&mut self, value: &str) {
        *TIPP_ZEIT.lock().unwrap() = Some(std::time::Instant::now());
        // Dead Key: Zeichen erst zurückhalten und nur einsetzen, wenn kein
        // Folgezeichen mehr kommt (sonst entsteht „´é" statt „é").
        if let Some((tot, t)) = self.pending_dead.take() {
            if t.elapsed() <= std::time::Duration::from_millis(700) {
                eprintln!("DEADKEY verworfen {:?} vor {:?}", tot, value);
            } else {
                self.insert_raw(&tot.to_string());
            }
        }
        let nur_ein_zeichen = value.chars().count() == 1;
        if nur_ein_zeichen {
            let c = value.chars().next().unwrap();
            if Self::TOT.contains(c) {
                self.pending_dead = Some((c, std::time::Instant::now()));
                eprintln!("DEADKEY zurueckgehalten {:?}", c);
                return;
            }
        }
        self.insert_raw(value);
    }

    fn insert_raw(&mut self, value: &str) {
        eprintln!("TEXTEINGANG label={:?} value={:?}", self.label, value);
        let at = self.byte_index(self.cursor);
        self.text.insert_str(at, value);
        self.cursor += value.encode_utf16().count();
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let at = self.byte_index(self.cursor);
        let prev = self.text[..at].char_indices().next_back().map(|(i, _)| i);
        if let Some(start) = prev {
            let removed = self.text[start..at].encode_utf16().count();
            self.text.replace_range(start..at, "");
            self.cursor -= removed;
        }
    }

    fn delete_forward(&mut self) {
        let at = self.byte_index(self.cursor);
        let next = self.text[at..].chars().next().map(|c| at + c.len_utf8());
        if let Some(end) = next {
            self.text.replace_range(at..end, "");
        }
    }

    fn move_cursor(&mut self, delta: isize) {
        let target = if delta < 0 {
            let at = self.byte_index(self.cursor);
            self.text[..at]
                .char_indices()
                .next_back()
                .map(|(i, _)| i)
                .map(|i| self.text[..i].encode_utf16().count())
        } else {
            let at = self.byte_index(self.cursor);
            self.text[at..]
                .chars()
                .next()
                .map(|c| self.cursor + c.len_utf16())
        };
        if let Some(target) = target {
            self.cursor = target;
        }
    }

    fn replace(&mut self, range: Option<Range<usize>>, value: &str) {
        eprintln!("REPLACE range={:?} value={:?}", range, value);
        match range {
            Some(range) => {
                let start = self.byte_index(range.start);
                let end = self.byte_index(range.end);
                self.text.replace_range(start..end, value);
                self.cursor = range.start + value.encode_utf16().count();
            }
            None => self.insert(value),
        }
    }
}

impl EntityInputHandler for TextField {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        _adjusted_range: &mut Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        let start = self.byte_index(range.start);
        let end = self.byte_index(range.end);
        Some(self.text[start..end].to_string())
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection { range: self.cursor..self.cursor, reversed: false })
    }

    fn marked_text_range(&self, _window: &mut Window, _cx: &mut Context<Self>) -> Option<Range<usize>> {
        None
    }

    fn unmark_text(&mut self, _window: &mut Window, _cx: &mut Context<Self>) {}

    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.replace(range, text);
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        new_text: &str,
        _new_selected_range: Option<Range<usize>>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.replace(range, new_text);
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        _range_utf16: Range<usize>,
        element_bounds: Bounds<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        Some(element_bounds)
    }

    fn character_index_for_point(
        &mut self,
        _point: Point<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        Some(self.cursor)
    }
}

impl Render for TextField {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = self.theme.clone();
        let focused = self.focus.is_focused(window);
        let empty = self.text.is_empty();
        let mut shown = if empty {
            self.placeholder.to_string()
        } else {
            self.text.clone()
        };
        if focused {
            shown.push('▏');
        }
        let ink = if empty { rgb(theme.ink3()) } else { rgb(theme.ink1()) };
        let border = if focused { theme.accent() } else { theme.line() };

        let id = ElementId::Name(self.label.clone());
        div()
            .id(id)
            .h(px(if self.multiline { 132. } else { 34. }))
            .w_full()
            .rounded_md()
            .border_1()
            .border_color(rgb(border))
            .bg(rgb(theme.surface()))
            .px_2()
            .py_1()
            .text_sm()
            .text_color(ink)
            .when(self.multiline, |this| this.flex().items_start())
            .child(shown)
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this: &mut TextField, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                eprintln!("FELD-KEY key={:?} key_char={:?}", key, event.keystroke.key_char);
                match key {
                    "backspace" => this.backspace(),
                    "delete" => this.delete_forward(),
                    "left" => this.move_cursor(-1),
                    "right" => this.move_cursor(1),
                    "home" => this.cursor = 0,
                    "end" => this.cursor = this.text.encode_utf16().count(),
                    _ => return,
                }
                cx.notify();
            }))
            .child(
                InputSink {
                    focus: self.focus.clone(),
                    view: cx.entity(),
                    style: StyleRefinement::default(),
                }
                    .w(px(0.))
                    .h(px(0.)),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _event: &MouseDownEvent, window, cx| {
                    window.focus(&this.focus);
                    cx.notify();
                }),
            )
    }
}

/// Element ohne Fläche: meldet dem Fenster beim Malen, wer Texteingaben bekommt.
struct InputSink {
    focus: FocusHandle,
    view: Entity<TextField>,
    style: StyleRefinement,
}

impl Element for InputSink {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.refine(&self.style);
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut (),
        _window: &mut Window,
        _cx: &mut App,
    ) -> () {
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut (),
        _prepaint: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        if self.focus.is_focused(window) {
            window.handle_input(
                &self.focus,
                ElementInputHandler::new(bounds, self.view.clone()),
                cx,
            );
        }
    }
}

impl IntoElement for InputSink {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Styled for InputSink {
    fn style(&mut self) -> &mut StyleRefinement {
        &mut self.style
    }
}
