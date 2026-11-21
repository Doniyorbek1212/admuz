from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.config import get_settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(get_settings().database_url, pool_size=20, max_overflow=20, pool_pre_ping=True)
SessionFactory = async_sessionmaker(engine, expire_on_commit=False)


def like_pattern(term: str) -> str:
    """%term% for ILIKE. The user's wildcards and the escape character are dropped: a trailing backslash is an SQL error."""
    return "%" + term.translate(str.maketrans("", "", "%_\\")) + "%"


async def get_db() -> AsyncIterator[AsyncSession]:
    async with SessionFactory() as session:
        yield session
